defmodule GptAgent do
  @moduledoc """
  Provides a GPT conversation agent
  """

  use GenServer
  use TypedStruct

  alias GptAgent.Events.{
    RunCompleted,
    RunStarted,
    ToolCallOutputRecorded,
    ToolCallRequested,
    UserMessageAdded
  }

  alias GptAgent.Values.NonblankString

  typedstruct do
    field :pid, pid(), enforce: true
    field :callback_handler, pid(), enforce: true
    field :default_assistant_id, binary(), enforce: true
    field :thread_id, binary() | nil
    field :running?, boolean(), default: false
    field :run_id, binary() | nil
    field :tool_calls, [ToolCallRequested.t()], default: []
    field :tool_outputs, [ToolCallOutputRecorded.t()], default: []
  end

  defp ok(state), do: {:ok, state}
  defp noreply(state), do: {:noreply, state}
  defp reply(state, reply), do: {:reply, reply, state}
  defp reply(state, reply, next), do: {:reply, reply, state, next}

  defp send_callback(state, callback) do
    send(state.callback_handler, {__MODULE__, state.pid, callback})
    state
  end

  def create_thread do
    {:ok, %{body: %{"id" => thread_id, "object" => "thread"}}} =
      OpenAiClient.post("/v1/threads", json: "")

    {:ok, thread_id}
  end

  @doc """
  Initializes the GPT Agent
  """
  @spec init(map()) :: {:ok, t()}
  def init(init_arg) do
    init_arg
    |> Enum.into(%{pid: self()})
    |> then(&struct!(__MODULE__, &1))
    |> ok()
  end

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

  defp heartbeat_interval_ms, do: Application.get_env(:gpt_agent, :heartbeat_interval_ms, 1000)

  def handle_cast({:set_default_assistant_id, assistant_id}, state) do
    {:noreply, %{state | default_assistant_id: assistant_id}}
  end

  def handle_call(:default_assistant_id, _caller, state) do
    reply(state, {:ok, state.default_assistant_id})
  end

  def handle_call({:add_user_message, _message}, _caller, %__MODULE__{running?: true} = state) do
    reply(state, {:error, :run_in_progress})
  end

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

  def handle_call(
        {:submit_tool_output, _tool_call_id, _tool_output},
        _caller,
        %__MODULE__{running?: false} = state
      ) do
    reply(state, {:error, :run_not_in_progress})
  end

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
    |> noreply()
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
  @spec start_link(pid(), binary(), binary()) :: {:ok, pid()} | {:error, reason :: term()}
  def start_link(callback_handler, assistant_id, thread_id)
      when is_pid(callback_handler) do
    GenServer.start_link(__MODULE__,
      callback_handler: callback_handler,
      default_assistant_id: assistant_id,
      thread_id: thread_id
    )
  end

  def default_assistant(pid) do
    GenServer.call(pid, :default_assistant_id)
  end

  def set_default_assistant(pid, assistant_id) do
    GenServer.cast(pid, {:set_default_assistant_id, assistant_id})
  end

  def add_user_message(pid, message) do
    GenServer.call(pid, {:add_user_message, message})
  end

  def submit_tool_output(pid, tool_call_id, tool_output) do
    GenServer.call(pid, {:submit_tool_output, tool_call_id, tool_output})
  end
end
