defmodule GptAgent do
  @moduledoc """
  Provides a GPT conversation agent
  """

  use GenServer
  use TypedStruct

  alias GptAgent.Events.{
    AssistantMessageAdded,
    RunCompleted,
    RunStarted,
    ToolCallOutputRecorded,
    ToolCallRequested,
    UserMessageAdded
  }

  alias GptAgent.Values.NonblankString

  typedstruct do
    field :default_assistant_id, binary()
    field :thread_id, binary() | nil
    field :running?, boolean(), default: false
    field :run_id, binary() | nil
    field :tool_calls, [ToolCallRequested.t()], default: []
    field :tool_outputs, [ToolCallOutputRecorded.t()], default: []
  end

  defp ok(state), do: {:ok, state}
  defp noreply(state), do: {:noreply, state}
  defp noreply(state, next), do: {:noreply, state, next}
  defp reply(state, reply), do: {:reply, reply, state}
  defp reply(state, reply, next), do: {:reply, reply, state, next}

  defp send_callback(state, callback) do
    Phoenix.PubSub.broadcast(GptAgent.PubSub, "gpt_agent:#{state.thread_id}", {self(), callback})
    state
  end

  @doc """
  Creates a new thread
  """
  @spec create_thread() :: {:ok, binary()}
  def create_thread do
    {:ok, %{body: %{"id" => thread_id, "object" => "thread"}}} =
      OpenAiClient.post("/v1/threads", json: "")

    {:ok, thread_id}
  end

  @impl true
  def init(init_arg) do
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
        Registry.register(GptAgent.Registry, thread_id, :gpt_agent)
        state
    end
  end

  @impl true
  def handle_continue(:run, state) do
    {:ok, %{body: %{"id" => id}}} =
      OpenAiClient.post("/v1/threads/#{state.thread_id}/runs",
        json: %{
          "assistant_id" => state.default_assistant_id
        }
      )

    Process.send_after(self(), {:check_run_status, id}, heartbeat_interval_ms())

    state
    |> Map.put(:running?, true)
    |> Map.put(:run_id, id)
    |> send_callback(%RunStarted{
      id: id,
      thread_id: state.thread_id,
      assistant_id: state.default_assistant_id
    })
    |> noreply()
  end

  @impl true
  def handle_continue(:read_messages, state) do
    {:ok, %{body: %{"object" => "list", "data" => messages}}} =
      OpenAiClient.get("/v1/threads/#{state.thread_id}/messages")

    for %{"role" => "assistant"} = message <- messages do
      [%{"text" => %{"value" => content}} | _rest] = message["content"]

      send_callback(state, %AssistantMessageAdded{
        message_id: message["id"],
        thread_id: message["thread_id"],
        run_id: message["run_id"],
        assistant_id: message["assistant_id"],
        content: content
      })
    end

    noreply(state)
  end

  defp heartbeat_interval_ms, do: Application.get_env(:gpt_agent, :heartbeat_interval_ms, 1000)

  @impl true
  def handle_cast({:set_default_assistant_id, assistant_id}, state) do
    {:noreply, %{state | default_assistant_id: assistant_id}}
  end

  @impl true
  def handle_call(:shutdown, _caller, state) do
    Registry.unregister(GptAgent.Registry, state.thread_id)
    ok(state)
  end

  @impl true
  def handle_call(:thread_id, _caller, %__MODULE__{} = state) do
    reply(state, {:ok, state.thread_id})
  end

  @impl true
  def handle_call(:default_assistant_id, _caller, %__MODULE__{} = state) do
    reply(state, {:ok, state.default_assistant_id})
  end

  @impl true
  def handle_call({:add_user_message, _message}, _caller, %__MODULE__{running?: true} = state) do
    reply(state, {:error, :run_in_progress})
  end

  @impl true
  def handle_call({:add_user_message, message}, _caller, state) do
    {:ok, message} = NonblankString.new(message)

    {:ok, %{body: %{"id" => id}}} =
      OpenAiClient.post("/v1/threads/#{state.thread_id}/messages", json: message)

    state
    |> send_callback(%UserMessageAdded{
      id: id,
      thread_id: state.thread_id,
      content: message
    })
    |> reply(:ok, {:continue, :run})
  end

  @impl true
  def handle_call(
        {:submit_tool_output, _tool_call_id, _tool_output},
        _caller,
        %__MODULE__{running?: false} = state
      ) do
    reply(state, {:error, :run_not_in_progress})
  end

  @impl true
  def handle_call({:submit_tool_output, tool_call_id, tool_output}, _caller, state) do
    case Enum.find_index(state.tool_calls, fn %ToolCallRequested{id: id} -> id == tool_call_id end) do
      nil ->
        reply(state, {:error, :invalid_tool_call_id})

      index ->
        {tool_call, tool_calls} = List.pop_at(state.tool_calls, index)

        tool_output = %ToolCallOutputRecorded{
          id: tool_call_id,
          thread_id: state.thread_id,
          run_id: tool_call.run_id,
          name: tool_call.name,
          output: Jason.encode!(tool_output)
        }

        tool_outputs = [tool_output | state.tool_outputs]

        state
        |> send_callback(tool_output)
        |> Map.put(:tool_calls, tool_calls)
        |> Map.put(:tool_outputs, tool_outputs)
        |> possibly_send_outputs_to_openai()
        |> reply(:ok)
    end
  end

  defp possibly_send_outputs_to_openai(
         %{running?: true, tool_calls: [], tool_outputs: [_ | _]} = state
       ) do
    OpenAiClient.post("/v1/threads/#{state.thread_id}/runs/#{state.run_id}/submit_tool_outputs",
      json: %{tool_outputs: state.tool_outputs}
    )

    Process.send_after(self(), {:check_run_status, state.run_id}, heartbeat_interval_ms())

    %{state | tool_outputs: []}
  end

  defp possibly_send_outputs_to_openai(state), do: state

  @impl true
  def handle_info({:check_run_status, id}, state) do
    {:ok, %{body: %{"status" => status} = response}} =
      OpenAiClient.get("/v1/threads/#{state.thread_id}/runs/#{id}", [])

    handle_run_status(status, id, response, state)
  end

  defp handle_run_status("completed", id, _response, state) do
    state
    |> Map.put(:running?, false)
    |> send_callback(%RunCompleted{
      id: id,
      thread_id: state.thread_id,
      assistant_id: state.default_assistant_id
    })
    |> noreply({:continue, :read_messages})
  end

  defp handle_run_status("requires_action", id, response, state) do
    %{"required_action" => %{"submit_tool_outputs" => %{"tool_calls" => tool_calls}}} = response

    tool_calls
    |> Enum.reduce(state, fn tool_call, state ->
      tool_call = %ToolCallRequested{
        id: tool_call["id"],
        thread_id: state.thread_id,
        run_id: id,
        name: tool_call["function"]["name"],
        arguments: Jason.decode!(tool_call["function"]["arguments"])
      }

      state
      |> Map.put(:tool_calls, [tool_call | state.tool_calls])
      |> send_callback(tool_call)
    end)
    |> noreply()
  end

  defp handle_run_status(_status, id, _response, state) do
    Process.send_after(self(), {:check_run_status, id}, heartbeat_interval_ms())
    noreply(state)
  end

  @doc """
  Starts the GPT Agent
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, reason :: term()}
  def start_link(init_arg) do
    GenServer.start_link(__MODULE__, init_arg)
  end

  @doc """
  Connects to the GPT Agent
  """
  @spec connect(binary()) :: {:ok, pid()} | {:error, :invalid_thread_id}
  def connect(thread_id) do
    case Registry.lookup(GptAgent.Registry, thread_id) do
      [{pid, :gpt_agent}] ->
        Phoenix.PubSub.subscribe(GptAgent.PubSub, "gpt_agent:#{thread_id}")
        {:ok, pid}

      [] ->
        case OpenAiClient.get("/v1/threads/#{thread_id}") do
          {:ok, %{status: 404}} ->
            {:error, :invalid_thread_id}

          {:ok, _} ->
            Phoenix.PubSub.subscribe(GptAgent.PubSub, "gpt_agent:#{thread_id}")

            DynamicSupervisor.start_child(
              GptAgent.Supervisor,
              {__MODULE__, [thread_id: thread_id]}
            )
        end
    end
  end

  @doc """
  Connects to the GPT Agent and sets the default assistant
  """
  @spec connect(binary(), binary()) :: {:ok, pid()} | {:error, :invalid_thread_id}
  def connect(thread_id, assistant_id) do
    case connect(thread_id) do
      {:ok, pid} ->
        :ok = set_default_assistant(pid, assistant_id)
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def shutdown(pid) do
    :ok = DynamicSupervisor.terminate_child(GptAgent.Supervisor, pid)
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
  @spec add_user_message(pid(), binary()) :: {:ok, binary()} | {:error, :run_in_progress}
  def add_user_message(pid, message) do
    GenServer.call(pid, {:add_user_message, message})
  end

  @doc """
  Submits tool output
  """
  @spec submit_tool_output(pid(), binary(), map()) ::
          {:ok, binary()} | {:error, :invalid_tool_call_id}
  def submit_tool_output(pid, tool_call_id, tool_output) do
    GenServer.call(pid, {:submit_tool_output, tool_call_id, tool_output})
  end
end
