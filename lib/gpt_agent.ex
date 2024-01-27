defmodule GptAgent do
  @moduledoc """
  Provides a GPT conversation agent
  """

  use GenServer
  use TypedStruct
  use Knigge, otp_app: :gpt_agent, default: __MODULE__.Impl

  require Logger

  alias GptAgent.Events.{
    AssistantMessageAdded,
    RunCompleted,
    RunStarted,
    ToolCallOutputRecorded,
    ToolCallRequested,
    UserMessageAdded
  }

  # two minutes
  @timeout_ms 120_000

  typedstruct do
    field :default_assistant_id, binary()
    field :thread_id, binary() | nil
    field :running?, boolean(), default: false
    field :run_id, binary() | nil
    field :tool_calls, [ToolCallRequested.t()], default: []
    field :tool_outputs, [ToolCallOutputRecorded.t()], default: []
    field :last_message_id, binary() | nil
    field :timeout_ms, non_neg_integer(), default: @timeout_ms
  end

  @type thread_id() :: binary()
  @type assistant_id() :: binary()

  @type connect_opt() ::
          {:subscribe, boolean()} | {:thread_id, thread_id()} | {:assistant_id, assistant_id()}
  @type connect_opts() :: list(connect_opt())

  @callback create_thread() :: {:ok, binary()}
  @callback start_link(keyword()) :: {:ok, pid()} | {:error, reason :: term()}
  @callback connect(connect_opts()) :: {:ok, pid()} | {:error, :invalid_thread_id}
  @callback shutdown(pid()) :: :ok
  @callback thread_id(pid()) :: binary()
  @callback default_assistant(pid()) :: binary()
  @callback set_default_assistant(pid(), binary()) :: :ok
  @callback add_user_message(pid(), binary()) :: {:ok, binary()} | {:error, :run_in_progress}
  @callback submit_tool_output(pid(), binary(), map()) ::
              {:ok, binary()} | {:error, :invalid_tool_call_id}

  defp ok(state), do: {:ok, state, state.timeout_ms}
  defp noreply(state), do: {:noreply, state, state.timeout_ms}
  defp noreply(state, next), do: {:noreply, state, next}
  defp reply(state, reply), do: {:reply, reply, state, state.timeout_ms}
  defp reply(state, reply, next), do: {:reply, reply, state, next}
  defp stop(state), do: {:stop, :normal, state}

  defp log(message, level \\ :debug),
    do: Logger.log(level, "[GptAgent (#{inspect(self())})] " <> message)

  defp publish_event(state, callback) do
    channel = "gpt_agent:#{state.thread_id}"
    log("Publishing event on channel #{channel}: #{inspect(callback)}")

    :ok = Phoenix.PubSub.broadcast(GptAgent.PubSub, channel, {self(), callback})

    state
  end

  @impl true
  def init(init_arg) do
    log("Initializing with #{inspect(init_arg)}")

    init_arg
    |> then(&struct!(__MODULE__, &1))
    |> register()
    |> ok()
  end

  defp register(state) do
    case state.thread_id do
      nil ->
        state

      thread_id ->
        {:ok, _pid} = Registry.register(GptAgent.Registry, thread_id, :gpt_agent)

        log("Registered in GptAgent.Registry as #{inspect(thread_id)}")

        state
    end
  end

  @impl true
  def handle_continue(:run, state) do
    log("Starting run")

    {:ok, %{body: %{"id" => id}}} =
      OpenAiClient.post("/v1/threads/#{state.thread_id}/runs",
        json: %{
          "assistant_id" => state.default_assistant_id
        }
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
        assistant_id: state.default_assistant_id
      )
    )
    |> noreply()
  end

  @impl true
  def handle_continue(:read_messages, state) do
    url =
      "/v1/threads/#{state.thread_id}/messages?order=asc" <>
        if state.last_message_id do
          "&after=#{state.last_message_id}"
        else
          ""
        end

    log("Reading messages with request to #{url}")
    {:ok, %{body: %{"object" => "list", "data" => messages}}} = OpenAiClient.get(url)

    state
    |> process_messages(messages)
    |> noreply()
  end

  defp process_messages(state, messages) do
    log("Processing messages: #{inspect(messages)}")

    Enum.reduce(messages, state, fn message, state ->
      [%{"text" => %{"value" => content}} | _rest] = message["content"]

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
    end)
  end

  defp heartbeat_interval_ms, do: Application.get_env(:gpt_agent, :heartbeat_interval_ms, 1000)

  @impl true
  def handle_cast({:set_default_assistant_id, assistant_id}, state) do
    log("Setting default assistant ID to #{assistant_id}")
    {:noreply, %{state | default_assistant_id: assistant_id}}
  end

  @impl true
  def handle_call(:shutdown, _caller, state) do
    log("Shutting down")
    Registry.unregister(GptAgent.Registry, state.thread_id)
    stop(state)
  end

  @impl true
  def handle_call(:thread_id, _caller, %__MODULE__{} = state) do
    log("Returning thread ID #{inspect(state.thread_id)}")
    reply(state, {:ok, state.thread_id})
  end

  @impl true
  def handle_call(:default_assistant_id, _caller, %__MODULE__{} = state) do
    log("Returning default assistant ID #{inspect(state.default_assistant_id)}")
    reply(state, {:ok, state.default_assistant_id})
  end

  @impl true
  def handle_call({:add_user_message, message}, _caller, %__MODULE__{running?: true} = state) do
    log(
      "Attempting to add user message, but run in progress, cannot add user message: #{inspect(message)}"
    )

    reply(state, {:error, :run_in_progress})
  end

  @impl true
  def handle_call({:add_user_message, message}, _caller, state) do
    log("Adding user message #{inspect(message)}")

    {:ok, %{body: %{"id" => id}}} =
      OpenAiClient.post("/v1/threads/#{state.thread_id}/messages", json: message)

    state
    |> publish_event(
      UserMessageAdded.new!(
        id: id,
        thread_id: state.thread_id,
        content: message
      )
    )
    |> reply(:ok, {:continue, :run})
  end

  @impl true
  def handle_call(
        {:submit_tool_output, tool_call_id, tool_output},
        _caller,
        %__MODULE__{running?: false} = state
      ) do
    log(
      "Attempting to submit tool output, but no run in progress, cannot submit tool output for call #{inspect(tool_call_id)}: #{inspect(tool_output)}"
    )

    reply(state, {:error, :run_not_in_progress})
  end

  @impl true
  def handle_call({:submit_tool_output, tool_call_id, tool_output}, _caller, state) do
    log("Submitting tool output #{inspect(tool_output)}")

    case Enum.find_index(state.tool_calls, fn %ToolCallRequested{id: id} -> id == tool_call_id end) do
      nil ->
        log("Tool call ID #{inspect(tool_call_id)} not found")
        reply(state, {:error, :invalid_tool_call_id})

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
        |> reply(:ok)
    end
  end

  defp possibly_send_outputs_to_openai(
         %{running?: true, tool_calls: [], tool_outputs: [_ | _]} = state
       ) do
    log("Sending tool outputs to OpenAI")

    {:ok, %{body: %{"object" => "thread.run", "cancelled_at" => nil, "failed_at" => nil}}} =
      OpenAiClient.post("/v1/threads/#{state.thread_id}/runs/#{state.run_id}/submit_tool_outputs",
        json: %{tool_outputs: state.tool_outputs}
      )

    Process.send_after(self(), {:check_run_status, state.run_id}, heartbeat_interval_ms())

    %{state | tool_outputs: []}
  end

  defp possibly_send_outputs_to_openai(state), do: state

  @impl true
  def handle_info(:timeout, state) do
    log("Timeout Received")

    if state.running? do
      log("Run in progress, checking run status")
      noreply(state, {:continue, {:check_run_status, state.run_id}})
    else
      log("Shutting down.")
      stop(state)
    end
  end

  @impl true
  def handle_info({:check_run_status, id}, state) do
    log("Checking run status for run ID #{inspect(id)}")

    {:ok, %{body: %{"status" => status} = response}} =
      OpenAiClient.get("/v1/threads/#{state.thread_id}/runs/#{id}", [])

    handle_run_status(status, id, response, state)
  end

  defp handle_run_status("completed", id, _response, state) do
    log("Run ID #{inspect(id)} completed")

    state
    |> Map.put(:running?, false)
    |> publish_event(
      RunCompleted.new!(
        id: id,
        thread_id: state.thread_id,
        assistant_id: state.default_assistant_id
      )
    )
    |> noreply({:continue, :read_messages})
  end

  defp handle_run_status("requires_action", id, response, state) do
    log("Run ID #{inspect(id)} requires action")
    %{"required_action" => %{"submit_tool_outputs" => %{"tool_calls" => tool_calls}}} = response
    log("Tool calls: #{inspect(tool_calls)}")

    tool_calls
    |> Enum.reduce(state, fn tool_call, state ->
      tool_call =
        ToolCallRequested.new!(
          id: tool_call["id"],
          thread_id: state.thread_id,
          run_id: id,
          name: tool_call["function"]["name"],
          arguments: Jason.decode!(tool_call["function"]["arguments"])
        )

      state
      |> Map.put(:tool_calls, [tool_call | state.tool_calls])
      |> publish_event(tool_call)
    end)
    |> noreply()
  end

  defp handle_run_status(_status, id, _response, state) do
    log("Run ID #{inspect(id)} not completed")
    Process.send_after(self(), {:check_run_status, id}, heartbeat_interval_ms())
    log("Will check run status in #{heartbeat_interval_ms()} ms")
    noreply(state)
  end

  defmodule Impl do
    @moduledoc """
    Provides the implementation of the GptAgent public API
    """

    defp log(message, level \\ :debug),
      do: Logger.log(level, "[GptAgent (#{inspect(self())})] " <> message)

    @doc """
    Creates a new thread
    """
    @spec create_thread() :: {:ok, binary()}
    def create_thread do
      log("Creating thread")

      {:ok, %{body: %{"id" => thread_id, "object" => "thread"}}} =
        OpenAiClient.post("/v1/threads", json: "")

      log("Created thread with ID #{inspect(thread_id)}")

      {:ok, thread_id}
    end

    @doc false
    @spec start_link(keyword()) :: {:ok, pid()} | {:error, reason :: term()}
    def start_link(init_arg) do
      GenServer.start_link(GptAgent, init_arg)
    end

    @doc """
    Connects to the GPT Agent
    """
    @spec connect(GptAgent.connect_opts()) :: {:ok, pid()} | {:error, :invalid_thread_id}
    def connect(opts) when is_list(opts) do
      opts = validate_and_convert_opts(opts)

      opts
      |> connect_to_new_or_existing_agent()
      |> maybe_set_default_assistant_id(opts)
      |> maybe_subscribe(opts)
    end

    defp connect_to_new_or_existing_agent(opts) do
      log("Connecting to thread ID #{inspect(opts.thread_id)}")

      case Registry.lookup(GptAgent.Registry, opts.thread_id) do
        [{pid, :gpt_agent}] ->
          handle_existing_agent(pid)

        [] ->
          handle_no_existing_agent(opts.thread_id, opts.timeout_ms)
      end
    end

    defp validate_and_convert_opts(opts) do
      Keyword.validate!(opts, [
        :thread_id,
        subscribe: true,
        assistant_id: nil,
        last_message_id: nil,
        timeout_ms: nil
      ])
      |> Enum.into(%{})
    end

    defp maybe_subscribe({:ok, _pid} = result, opts) do
      if opts.subscribe do
        Phoenix.PubSub.subscribe(GptAgent.PubSub, "gpt_agent:#{opts.thread_id}")
      end

      result
    end

    defp maybe_subscribe(result, _opts), do: result

    defp handle_existing_agent(pid) do
      log("Found existing GPT Agent with PID #{inspect(pid)}")
      {:ok, pid}
    end

    defp handle_no_existing_agent(thread_id, timeout_ms) do
      log("No existing GPT Agent found, starting new one")

      timeout_opt =
        if timeout_ms do
          log("Setting GPT Agent timeout to #{timeout_ms}ms")
          [timeout_ms: timeout_ms]
        else
          []
        end

      case OpenAiClient.get("/v1/threads/#{thread_id}") do
        {:ok, %{status: 404}} ->
          log("Thread ID #{inspect(thread_id)} not found")
          {:error, :invalid_thread_id}

        {:ok, _} ->
          log("Thread ID #{inspect(thread_id)} found")

          child_spec = %{
            id: thread_id,
            start: {__MODULE__, :start_link, [[{:thread_id, thread_id} | timeout_opt]]},
            restart: :temporary
          }

          DynamicSupervisor.start_child(GptAgent.Supervisor, child_spec)
          |> tap(&log("Started GPT Agent with result #{inspect(&1)}"))
      end
    end

    defp maybe_set_default_assistant_id({:ok, pid} = result, opts) do
      if opts.assistant_id do
        :ok = set_default_assistant(pid, opts.assistant_id)
      end

      result
    end

    defp maybe_set_default_assistant_id(result, _opts), do: result

    def connect(thread_id, assistant_id) when is_binary(assistant_id) do
      log(
        "Connecting to thread ID #{inspect(thread_id)} and setting default assistant ID to #{inspect(assistant_id)}"
      )

      case connect(thread_id) do
        {:ok, pid} ->
          :ok = set_default_assistant(pid, assistant_id)
          {:ok, pid}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @spec shutdown(pid()) :: :ok
    def shutdown(pid) do
      log("Shutting down GPT Agent with PID #{inspect(pid)}")

      if Process.alive?(pid) do
        log("GPT Agent with PID #{inspect(pid)} is alive, terminating")
        :ok = DynamicSupervisor.terminate_child(GptAgent.Supervisor, pid)
      else
        log("GPT Agent with PID #{inspect(pid)} is not alive")
      end

      :ok
    end

    @doc """
    Returns the thread ID
    """
    @spec thread_id(pid()) :: binary()
    def thread_id(pid) do
      GenServer.call(pid, :thread_id)
    end

    @doc """
    Returns the default assistant
    """
    @spec default_assistant(pid()) :: binary()
    def default_assistant(pid) do
      GenServer.call(pid, :default_assistant_id)
    end

    @doc """
    Sets the default assistant
    """
    @spec set_default_assistant(pid(), binary()) :: :ok
    def set_default_assistant(pid, assistant_id) do
      GenServer.cast(pid, {:set_default_assistant_id, assistant_id})
    end

    @doc """
    Adds a user message
    """
    @spec add_user_message(pid(), binary()) :: :ok | {:error, :run_in_progress}
    def add_user_message(pid, message) do
      GenServer.call(pid, {:add_user_message, message})
    end

    @doc """
    Submits tool output
    """
    @spec submit_tool_output(pid(), binary(), map()) :: :ok | {:error, :invalid_tool_call_id}
    def submit_tool_output(pid, tool_call_id, tool_output) do
      GenServer.call(pid, {:submit_tool_output, tool_call_id, tool_output})
    end
  end
end
