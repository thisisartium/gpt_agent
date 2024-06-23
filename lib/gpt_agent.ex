defmodule GptAgent do
  @moduledoc """
  Provides a GPT conversation agent
  """

  use GenServer
  use GptAgent.Types
  use Knigge, otp_app: :gpt_agent, default: __MODULE__.Impl

  require Logger

  alias GptAgent.Types

  alias Types.UserMessage

  alias GptAgent.Events.{
    AssistantMessageAdded,
    OrganizationQuotaExceeded,
    RateLimited,
    RateLimitRetriesExhuasted,
    RunCompleted,
    RunFailed,
    RunStarted,
    ToolCallOutputRecorded,
    ToolCallOutputSubmissionFailed,
    ToolCallRequested,
    UserMessageAdded
  }

  # two minutes
  @timeout_ms 120_000

  @rate_limit_max_retries Application.compile_env(:gpt_agent, :rate_limit_max_retries, 10)
  @rate_limit_retry_delay Application.compile_env(:gpt_agent, :rate_limit_retry_delay, 30_000)

  @tool_output_retry_delay Application.compile_env(:gpt_agent, :tool_output_retry_delay, 1000)

  typedstruct do
    field :assistant_id, Types.assistant_id(), enforce: true
    field :thread_id, Types.thread_id(), enforce: true
    field :last_message_id, Types.message_id() | nil, enforce: true
    field :running?, boolean(), default: false
    field :run_id, Types.run_id() | nil
    field :tool_calls, [ToolCallRequested.t()], default: []
    field :tool_outputs, [ToolCallOutputRecorded.t()], default: []
    field :timeout_ms, non_neg_integer(), default: @timeout_ms
    field :rate_limit_retry_attempt, non_neg_integer(), default: 0
  end

  @type connect_opt() ::
          {:subscribe, boolean()}
          | {:thread_id, Types.thread_id()}
          | {:assistant_id, Types.assistant_id()}
  @type connect_opts() :: list(connect_opt())

  @callback create_thread() :: {:ok, Types.thread_id()}
  @callback start_link(t()) :: Types.result(pid(), term())
  @callback connect(connect_opts()) :: Types.result(pid(), :invalid_thread_id)
  @callback shutdown(pid()) :: Types.result({:process_not_alive, pid()})
  @callback add_user_message(pid(), Types.nonblank_string()) ::
              Types.result(:run_in_progress | {:process_not_alive, pid()})
  @callback submit_tool_output(pid(), Types.tool_name(), Types.tool_output()) ::
              Types.result(:invalid_tool_call_id | {:process_not_alive, pid()})
  @callback run_in_progress?(pid()) :: boolean() | Types.error({:process_not_alive, pid()})
  @callback set_assistant_id(pid(), Types.assistant_id()) ::
              Types.result({:process_not_alive, pid()})

  defp noreply(%__MODULE__{} = state), do: {:noreply, state, state.timeout_ms}
  defp noreply(%__MODULE__{} = state, next), do: {:noreply, state, next}
  defp reply(%__MODULE__{} = state, reply), do: {:reply, reply, state, state.timeout_ms}
  defp stop(%__MODULE__{} = state), do: {:stop, :normal, state}

  defp log(message, level \\ :debug) when is_binary(message),
    do: Logger.log(level, "[GptAgent (#{inspect(self())})] " <> message)

  defp publish_event(%__MODULE__{} = state, callback) do
    channel = "gpt_agent:#{state.thread_id}"
    log("Publishing event on channel #{channel}: #{inspect(callback)}")

    :ok = Phoenix.PubSub.broadcast(GptAgent.PubSub, channel, {self(), callback})

    state
  end

  @impl true
  def init(%__MODULE__{} = state) do
    ensure_type!(state)

    log("Initializing with #{inspect(state)}")

    state
    |> register()
    |> retrieve_current_run_status()
    |> then(&{:ok, &1, {:continue, {:check_run_status, &1.run_id}}})
  end

  defp register(%__MODULE__{} = state) do
    case state.thread_id do
      nil ->
        state

      thread_id ->
        {:ok, _pid} = Registry.register(GptAgent.Registry, thread_id, :gpt_agent)

        log("Registered in GptAgent.Registry as #{inspect(thread_id)}")

        state
    end
  end

  defp receive_timeout_ms(%__MODULE__{} = state) do
    default_receive_timeout_ms = Application.get_env(:gpt_agent, :receive_timeout_ms)
    Enum.min([default_receive_timeout_ms, state.timeout_ms])
  end

  defp retrieve_current_run_status(%__MODULE__{} = state) do
    {:ok, %{body: %{"object" => "list", "data" => runs}}} =
      OpenAiClient.get("/v1/threads/#{state.thread_id}/runs?limit=1&order=desc",
        receive_timeout: receive_timeout_ms(state)
      )

    case runs do
      [%{"id" => run_id, "status" => status} | _rest]
      when status in ~w(queued in_progress requires_action) ->
        state
        |> Map.put(:running?, true)
        |> Map.put(:run_id, run_id)

      _ ->
        state
    end
  end

  @impl true
  def handle_continue(:run, %__MODULE__{} = state) do
    log("Starting run")

    {:ok, %{body: %{"id" => id}}} =
      OpenAiClient.post("/v1/threads/#{state.thread_id}/runs",
        json: %{
          "assistant_id" => state.assistant_id
        },
        receive_timeout: receive_timeout_ms(state)
      )

    Process.send_after(self(), {:check_run_status, id}, heartbeat_interval_ms())
    log("Will check run status in #{heartbeat_interval_ms()} ms")

    state
    |> Map.put(:running?, true)
    |> Map.put(:run_id, id)
    |> publish_event(
      RunStarted.new!(
        id: id,
        thread_id: state.thread_id,
        assistant_id: state.assistant_id
      )
    )
    |> noreply()
  end

  @impl true
  def handle_continue({:check_run_status, nil}, state) do
    log("No run in progress, not checking run status")
    noreply(state)
  end

  @impl true
  def handle_continue({:check_run_status, run_id}, state) do
    handle_info({:check_run_status, run_id}, state)
  end

  @impl true
  def handle_continue(:read_messages, %__MODULE__{} = state) do
    url =
      "/v1/threads/#{state.thread_id}/messages?order=asc" <>
        if state.last_message_id do
          "&after=#{state.last_message_id}"
        else
          ""
        end

    log("Reading messages with request to #{url}")

    {:ok, %{body: %{"object" => "list", "data" => messages}}} =
      OpenAiClient.get(url, receive_timeout: receive_timeout_ms(state))

    state
    |> process_messages(messages)
    |> noreply()
  end

  defp process_message(message, %__MODULE__{} = state) do
    case message["content"] do
      [%{"text" => %{"value" => content}} | _rest] ->
        if message["role"] == "assistant" do
          publish_event(
            state,
            AssistantMessageAdded.new!(
              message_id: message["id"],
              thread_id: message["thread_id"],
              run_id: message["run_id"],
              assistant_id: message["assistant_id"],
              content: content
            )
          )

          log("Updating last message ID to #{message["id"]}")
          %{state | last_message_id: message["id"]}
        else
          state
        end

      _ ->
        log("Skipping message with no content: #{inspect(message)}")
        state
    end
  end

  defp process_messages(%__MODULE__{} = state, messages) do
    log("Processing messages: #{inspect(messages)}")
    Enum.reduce(messages, state, &process_message/2)
  end

  defp heartbeat_interval_ms, do: Application.get_env(:gpt_agent, :heartbeat_interval_ms, 1000)

  @impl true
  def handle_cast({:set_assistant_id, assistant_id}, %__MODULE__{} = state) do
    log("Setting default assistant ID to #{assistant_id}")
    {:noreply, %{state | assistant_id: assistant_id}}
  end

  def handle_cast({:set_last_message_id, last_message_id}, %__MODULE__{} = state) do
    log("Setting last message ID to #{last_message_id}")
    {:noreply, %{state | last_message_id: last_message_id}}
  end

  def handle_cast({:add_user_message, message}, %__MODULE__{running?: true} = state) do
    log(
      "Attempting to add user message, but run in progress, cannot add user message: #{inspect(message)}"
    )

    GenServer.cast(self(), {:add_user_message, message})
    noreply(state)
  end

  def handle_cast({:add_user_message, %UserMessage{} = message}, %__MODULE__{} = state) do
    log("Adding user message #{inspect(message)}")

    {:ok, %{body: %{"id" => id}}} =
      OpenAiClient.post("/v1/threads/#{state.thread_id}/messages",
        json: message,
        receive_timeout: receive_timeout_ms(state)
      )

    state
    |> Map.put(:rate_limit_retry_attempt, 0)
    |> publish_event(
      UserMessageAdded.new!(
        id: id,
        thread_id: state.thread_id,
        content: message
      )
    )
    |> noreply({:continue, :run})
  end

  def handle_cast(
        {:submit_tool_output, tool_call_id, tool_output},
        %__MODULE__{running?: false} = state
      ) do
    log(
      "Attempting to submit tool output, but no run in progress, cannot submit tool output for call #{inspect(tool_call_id)}: #{inspect(tool_output)}"
    )

    noreply(state)
  end

  def handle_cast(
        {:submit_tool_output, tool_call_id, tool_output},
        %__MODULE__{} = state
      ) do
    log("Submitting tool output #{inspect(tool_output)}")

    case Enum.find_index(state.tool_calls, fn %ToolCallRequested{id: id} -> id == tool_call_id end) do
      nil ->
        log("Tool call ID #{inspect(tool_call_id)} not found")
        noreply(state)

      index ->
        log("Tool call ID #{inspect(tool_call_id)} found at index #{inspect(index)}")
        {tool_call, tool_calls} = List.pop_at(state.tool_calls, index)

        tool_output =
          ToolCallOutputRecorded.new!(
            id: tool_call_id,
            thread_id: state.thread_id,
            run_id: tool_call.run_id,
            name: tool_call.name,
            output: Jason.encode!(tool_output)
          )

        tool_outputs = [tool_output | state.tool_outputs]

        state
        |> publish_event(tool_output)
        |> Map.put(:tool_calls, tool_calls)
        |> Map.put(:tool_outputs, tool_outputs)
        |> possibly_send_outputs_to_openai()
        |> noreply()
    end
  end

  defp possibly_send_outputs_to_openai(state, failure_count \\ 0)

  defp possibly_send_outputs_to_openai(state, failure_count) when failure_count >= 3 do
    log("Failed to send tool outputs to OpenAI after 3 attempts, giving up", :warning)

    state
    |> publish_event(
      ToolCallOutputSubmissionFailed.new!(
        thread_id: state.thread_id,
        run_id: state.run_id
      )
    )
  end

  defp possibly_send_outputs_to_openai(
         %__MODULE__{running?: true, tool_calls: [], tool_outputs: [_ | _]} = state,
         failure_count
       ) do
    log("Sending tool outputs to OpenAI")

    try do
      {:ok, %{body: %{"object" => "thread.run", "cancelled_at" => nil, "failed_at" => nil}}} =
        OpenAiClient.post(
          "/v1/threads/#{state.thread_id}/runs/#{state.run_id}/submit_tool_outputs",
          json: %{tool_outputs: state.tool_outputs},
          receive_timeout: receive_timeout_ms(state)
        )
    rescue
      exception ->
        log("Failed to send tool outputs to OpenAI: #{inspect(exception)}", :warning)
        :timer.sleep(@tool_output_retry_delay)
        possibly_send_outputs_to_openai(state, failure_count + 1)
    end

    Process.send_after(self(), {:check_run_status, state.run_id}, heartbeat_interval_ms())

    %{state | tool_outputs: []}
  end

  defp possibly_send_outputs_to_openai(%__MODULE__{} = state, _failure_count), do: state

  @impl true
  def handle_call(:run_in_progress?, _caller, %__MODULE__{} = state) do
    reply(state, state.running?)
  end

  def handle_call(:shutdown, _caller, %__MODULE__{} = state) do
    log("Shutting down")
    Registry.unregister(GptAgent.Registry, state.thread_id)
    stop(state)
  end

  def handle_call(:thread_id, _caller, %__MODULE__{} = state) do
    log("Returning thread ID #{inspect(state.thread_id)}")
    reply(state, {:ok, state.thread_id})
  end

  def handle_call(:assistant_id, _caller, %__MODULE__{} = state) do
    log("Returning default assistant ID #{inspect(state.assistant_id)}")
    reply(state, {:ok, state.assistant_id})
  end

  @impl true
  def handle_info(:timeout, %__MODULE__{} = state) do
    log("Timeout Received")

    if state.running? do
      log("Run in progress, checking run status")
      noreply(state, {:continue, {:check_run_status, state.run_id}})
    else
      log("Shutting down.")
      stop(state)
    end
  end

  def handle_info(:run, %__MODULE__{} = state) do
    noreply(state, {:continue, :run})
  end

  def handle_info({:check_run_status, id}, %__MODULE__{} = state) do
    log("Checking run status for run ID #{inspect(id)}")

    {:ok, %{body: %{"status" => status} = response}} =
      OpenAiClient.get("/v1/threads/#{state.thread_id}/runs/#{id}",
        receive_timeout: receive_timeout_ms(state)
      )

    handle_run_status(status, id, response, state)
  end

  defp handle_run_status("completed", id, response, %__MODULE__{} = state) do
    log("Run ID #{inspect(id)} completed")

    state
    |> Map.put(:running?, false)
    |> publish_event(
      RunCompleted.new!(
        id: id,
        thread_id: state.thread_id,
        assistant_id: state.assistant_id,
        prompt_tokens: response |> Map.get("usage", %{}) |> Map.get("prompt_tokens", 0),
        completion_tokens: response |> Map.get("usage", %{}) |> Map.get("completion_tokens", 0),
        total_tokens: response |> Map.get("usage", %{}) |> Map.get("total_tokens", 0)
      )
    )
    |> noreply({:continue, :read_messages})
  end

  defp handle_run_status("requires_action", id, response, %__MODULE__{} = state) do
    log("Run ID #{inspect(id)} requires action")
    %{"required_action" => %{"submit_tool_outputs" => %{"tool_calls" => tool_calls}}} = response
    log("Tool calls: #{inspect(tool_calls)}")

    tool_calls
    |> Enum.reduce(state, fn tool_call, state ->
      case Jason.decode(tool_call["function"]["arguments"]) do
        {:ok, arguments} ->
          tool_call =
            ToolCallRequested.new!(
              id: tool_call["id"],
              thread_id: state.thread_id,
              run_id: id,
              name: tool_call["function"]["name"],
              arguments: arguments
            )

          state
          |> Map.put(:tool_calls, [tool_call | state.tool_calls])
          |> publish_event(tool_call)

        {:error, %Jason.DecodeError{}} ->
          log("Failed to decode tool call arguments: #{inspect(tool_call)}", :warning)

          tool_output =
            ToolCallOutputRecorded.new!(
              id: tool_call["id"],
              thread_id: state.thread_id,
              run_id: id,
              name: tool_call["function"]["name"],
              output:
                Jason.encode!(%{error: "Failed to decode arguments, invalid JSON in tool call."})
            )

          state
          |> publish_event(tool_output)
          |> Map.put(:tool_outputs, [tool_output | state.tool_outputs])
      end
    end)
    |> possibly_send_outputs_to_openai()
    |> noreply()
  end

  defp handle_run_status(status, id, _response, %__MODULE__{} = state)
       when status in ~w(queued in_progress) do
    log("Run ID #{inspect(id)} not completed")
    Process.send_after(self(), {:check_run_status, id}, heartbeat_interval_ms())
    log("Will check run status in #{heartbeat_interval_ms()} ms")
    noreply(%{state | running?: true})
  end

  defp handle_run_status(
         "failed",
         id,
         %{
           "last_error" => %{
             "code" => "rate_limit_exceeded",
             "message" => "Rate limit reached" <> _
           }
         },
         %__MODULE__{rate_limit_retry_attempt: attempts} = state
       )
       when attempts < @rate_limit_max_retries do
    log(
      "Run ID #{inspect(id)} failed due to rate limiting. Will retry run in #{@rate_limit_retry_delay}ms."
    )

    Process.send_after(self(), :run, @rate_limit_retry_delay)

    state
    |> Map.update!(:rate_limit_retry_attempt, &(&1 + 1))
    |> publish_event(
      RateLimited.new!(
        run_id: id,
        thread_id: state.thread_id,
        assistant_id: state.assistant_id,
        retries_remaining: @rate_limit_max_retries - attempts
      )
    )
    |> noreply()
  end

  defp handle_run_status(
         "failed",
         id,
         %{
           "last_error" => %{
             "code" => "rate_limit_exceeded",
             "message" => "Rate limit reached" <> _
           }
         },
         %__MODULE__{rate_limit_retry_attempt: attempts} = state
       )
       when attempts >= @rate_limit_max_retries do
    log("Run ID #{inspect(id)} failed due to rate limiting. Retries expired")

    state
    |> Map.update!(:rate_limit_retry_attempt, &(&1 + 1))
    |> Map.put(:running?, false)
    |> publish_event(
      RateLimited.new!(
        run_id: id,
        thread_id: state.thread_id,
        assistant_id: state.assistant_id,
        retries_remaining: @rate_limit_max_retries - attempts
      )
    )
    |> publish_event(
      RateLimitRetriesExhuasted.new!(
        run_id: id,
        thread_id: state.thread_id,
        assistant_id: state.assistant_id
      )
    )
    |> noreply()
  end

  defp handle_run_status(
         "failed",
         id,
         %{
           "last_error" => %{
             "code" => "rate_limit_exceeded",
             "message" =>
               "You exceeded your current quota, please check your plan and billing details." <> _
           }
         } = response,
         %__MODULE__{} = state
       ) do
    log("Run ID #{inspect(id)} failed due to OpenAI account quota reached.")

    state
    |> Map.put(:running?, false)
    |> publish_event(
      OrganizationQuotaExceeded.new!(
        run_id: id,
        thread_id: state.thread_id,
        assistant_id: state.assistant_id
      )
    )
    # DEPRECATED: remove this second publish_event call on major version bump to 10.0.0
    |> publish_event(
      RunFailed.new!(
        id: id,
        thread_id: state.thread_id,
        assistant_id: state.assistant_id,
        code: "rate_limit_exceeded",
        message: response |> Map.get("last_error", %{}) |> Map.get("message")
      )
    )
    |> noreply()
  end

  defp handle_run_status(status, id, response, %__MODULE__{} = state) do
    log("Run ID #{inspect(id)} failed with status #{inspect(status)}", :warning)
    log("Response: #{inspect(response)}")
    log("State: #{inspect(state)}")

    state
    |> Map.put(:running?, false)
    |> publish_event(
      RunFailed.new!(
        id: id,
        thread_id: state.thread_id,
        assistant_id: state.assistant_id,
        code: response |> Map.get("last_error", %{}) |> Map.get("code") || "unknown",
        message: response |> Map.get("last_error", %{}) |> Map.get("message") || "unknown"
      )
    )
    |> noreply()
  end

  defmodule Impl do
    @moduledoc """
    Provides the implementation of the GptAgent public API
    """

    @behaviour GptAgent

    defp log(message, level \\ :debug) when is_binary(message),
      do: Logger.log(level, "[GptAgent (#{inspect(self())})] " <> message)

    defp ok(data), do: {:ok, data}

    @impl true
    def create_thread(json \\ "") do
      log("Creating thread")

      {:ok, %{body: %{"id" => thread_id, "object" => "thread"}}} =
        OpenAiClient.post("/v1/threads",
          json: json,
          receive_timeout: Application.get_env(:gpt_agent, :receive_timeout_ms)
        )

      log("Created thread with ID #{inspect(thread_id)}")

      {:ok, thread_id}
    end

    @impl true
    def start_link(%GptAgent{} = state) do
      GenServer.start_link(GptAgent, state)
    end

    @impl true
    def connect(opts) when is_list(opts) do
      {:ok, opts} = validate_and_convert_opts(opts)

      opts
      |> connect_to_new_or_existing_agent()
      |> maybe_subscribe(opts)
    end

    defp connect_to_new_or_existing_agent(opts) do
      log("Connecting to thread ID #{inspect(opts.thread_id)}")

      case Registry.lookup(GptAgent.Registry, opts.thread_id) do
        [{pid, :gpt_agent}] ->
          handle_existing_agent(pid, opts.last_message_id, opts.assistant_id)

        [] ->
          handle_no_existing_agent(
            opts.thread_id,
            opts.last_message_id,
            opts.assistant_id,
            opts.timeout_ms
          )
      end
    end

    defp validate_and_convert_opts(opts) do
      Keyword.validate!(opts, [
        :thread_id,
        :last_message_id,
        :assistant_id,
        subscribe: true,
        timeout_ms: nil
      ])
      |> Enum.into(%{})
      |> ok()
      |> validate_thread_id()
      |> validate_last_message_id()
      |> validate_assistant_id()
    end

    defp validate_thread_id({:ok, %{thread_id: _thread_id} = opts}) do
      ok(opts)
    end

    defp validate_thread_id({:ok, _opts}) do
      {:error, :missing_thread_id}
    end

    defp validate_last_message_id({:ok, %{last_message_id: _last_message_id} = opts}) do
      ok(opts)
    end

    defp validate_last_message_id({:ok, _opts}) do
      {:error, :missing_last_message_id}
    end

    defp validate_last_message_id({:error, _} = error), do: error

    defp validate_assistant_id({:ok, %{assistant_id: _assistant_id} = opts}) do
      ok(opts)
    end

    defp validate_assistant_id({:ok, _opts}) do
      {:error, :missing_assistant_id}
    end

    defp validate_assistant_id({:error, _} = error), do: error

    defp maybe_subscribe({:ok, _pid} = result, opts) do
      if opts.subscribe do
        Phoenix.PubSub.subscribe(GptAgent.PubSub, "gpt_agent:#{opts.thread_id}")
      end

      result
    end

    defp maybe_subscribe(result, _opts), do: result

    defp receive_timeout_ms(%GptAgent{} = state) do
      default_receive_timeout_ms = Application.get_env(:gpt_agent, :receive_timeout_ms)
      Enum.min([default_receive_timeout_ms, state.timeout_ms])
    end

    defp handle_existing_agent(pid, last_message_id, assistant_id) do
      log("Found existing GPT Agent with PID #{inspect(pid)}")
      log("Updating last message ID to #{inspect(last_message_id)}")
      GenServer.cast(pid, {:set_last_message_id, last_message_id})
      GenServer.cast(pid, {:set_assistant_id, assistant_id})
      {:ok, pid}
    end

    defp handle_no_existing_agent(thread_id, last_message_id, assistant_id, timeout_ms) do
      log("No existing GPT Agent found, starting new one")

      state =
        GptAgent.new!(
          thread_id: thread_id,
          last_message_id: last_message_id,
          assistant_id: assistant_id,
          timeout_ms: timeout_ms || default_timeout_ms()
        )

      case OpenAiClient.get("/v1/threads/#{thread_id}",
             receive_timeout: receive_timeout_ms(state)
           ) do
        {:ok, %{status: 404}} ->
          log("Thread ID #{inspect(thread_id)} not found")
          {:error, :invalid_thread_id}

        {:ok, _} ->
          log("Thread ID #{inspect(thread_id)} found")

          child_spec = %{
            id: thread_id,
            start: {__MODULE__, :start_link, [state]},
            restart: :temporary
          }

          DynamicSupervisor.start_child(GptAgent.Supervisor, child_spec)
          |> tap(&log("Started GPT Agent with result #{inspect(&1)}"))
      end
    end

    defp default_timeout_ms, do: Application.get_env(:gpt_agent, :timeout_ms, 120_000)

    defp handle_dead_process(pid) do
      log("GPT Agent with PID #{inspect(pid)} is not alive", :warning)
      {:error, {:process_not_alive, pid}}
    end

    @impl true
    def shutdown(pid) do
      log("Shutting down GPT Agent with PID #{inspect(pid)}")

      if Process.alive?(pid) do
        log("GPT Agent with PID #{inspect(pid)} is alive, terminating")
        DynamicSupervisor.terminate_child(GptAgent.Supervisor, pid)
      else
        handle_dead_process(pid)
      end
    end

    @impl true
    def add_user_message(pid, message) do
      if Process.alive?(pid) do
        GenServer.cast(pid, {:add_user_message, %UserMessage{content: message}})
      else
        handle_dead_process(pid)
      end
    end

    @impl true
    def submit_tool_output(pid, tool_call_id, tool_output) do
      if Process.alive?(pid) do
        GenServer.cast(pid, {:submit_tool_output, tool_call_id, tool_output})
      else
        handle_dead_process(pid)
      end
    end

    @impl true
    def run_in_progress?(pid) do
      if Process.alive?(pid) do
        GenServer.call(pid, :run_in_progress?)
      else
        handle_dead_process(pid)
      end
    end

    @impl true
    def set_assistant_id(pid, assistant_id) do
      if Process.alive?(pid) do
        GenServer.cast(pid, {:set_assistant_id, assistant_id})
      else
        handle_dead_process(pid)
      end
    end
  end
end
