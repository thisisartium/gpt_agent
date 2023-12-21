defmodule GptAgent do
  @moduledoc """
  Provides a GPT conversation agent
  """

  use GenServer
  use TypedStruct

  alias GptAgent.Events.{
    RunCompleted,
    RunStarted,
    ThreadCreated,
    ToolCallRequested,
    UserMessageAdded
  }

  alias GptAgent.Values.NonblankString

  typedstruct do
    field :pid, pid(), enforce: true
    field :callback_handler, pid(), enforce: true
    field :assistant_id, binary(), enforce: true
    field :thread_id, binary() | nil
    field :running?, boolean(), default: false
  end

  defp ok(state, next), do: {:ok, state, next}
  defp noreply(state), do: {:noreply, state}
  defp reply(state, reply), do: {:reply, reply, state}
  defp reply(state, reply, next), do: {:reply, reply, state, next}

  defp send_callback(state, callback) do
    send(state.callback_handler, {__MODULE__, state.pid, callback})
    state
  end

  @doc """
  Initializes the GPT Agent
  """
  @spec init(map()) :: {:ok, t(), {:continue, :create_thread}}
  def init(init_arg) do
    init_arg
    |> Enum.into(%{pid: self()})
    |> then(&struct!(__MODULE__, &1))
    |> ok({:continue, :create_thread})
  end

  def handle_continue(:create_thread, %__MODULE__{thread_id: nil} = state) do
    {:ok, %{body: %{"id" => thread_id}}} = OpenAiClient.post("/v1/threads", json: "")

    state
    |> Map.put(:thread_id, thread_id)
    |> send_callback(%ThreadCreated{id: thread_id})
    |> send_callback(:ready)
    |> noreply()
  end

  def handle_continue(:create_thread, state) do
    state
    |> send_callback(:ready)
    |> noreply()
  end

  def handle_continue(:run, state) do
    {:ok, %{body: %{"id" => id}}} =
      OpenAiClient.post("/v1/threads/#{state.thread_id}/runs",
        json: %{
          "assistant_id" => state.assistant_id
        }
      )

    Process.send_after(self(), {:check_run_status, id}, heartbeat_interval_ms())

    state
    |> Map.put(:running?, true)
    |> send_callback(%RunStarted{
      id: id,
      thread_id: state.thread_id,
      assistant_id: state.assistant_id
    })
    |> noreply()
  end

  defp heartbeat_interval_ms, do: Application.get_env(:gpt_agent, :heartbeat_interval_ms, 1000)

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

  def handle_info({:check_run_status, id}, state) do
    {:ok, %{body: %{"status" => status} = response}} =
      OpenAiClient.get("/v1/threads/#{state.thread_id}/runs/#{id}", [])

    handle_run_status(status, id, response, state)
  end

  defp handle_run_status("completed", id, _response, state) do
    state
    |> send_callback(%RunCompleted{
      id: id,
      thread_id: state.thread_id,
      assistant_id: state.assistant_id
    })
    |> noreply()
  end

  defp handle_run_status("requires_action", id, response, state) do
    %{"required_action" => %{"submit_tool_outputs" => %{"tool_calls" => tool_calls}}} = response

    tool_calls
    |> Enum.reduce(state, fn tool_call, state ->
      send_callback(state, %ToolCallRequested{
        id: tool_call["id"],
        thread_id: state.thread_id,
        run_id: id,
        name: tool_call["function"]["name"],
        arguments: Jason.decode!(tool_call["function"]["arguments"])
      })
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
  @spec start_link(pid(), binary(), binary() | nil) :: {:ok, pid()} | {:error, reason :: term()}
  def start_link(callback_handler, assistant_id, thread_id \\ nil)
      when is_pid(callback_handler) do
    GenServer.start_link(__MODULE__,
      callback_handler: callback_handler,
      assistant_id: assistant_id,
      thread_id: thread_id
    )
  end

  def add_user_message(pid, message) do
    GenServer.call(pid, {:add_user_message, message})
  end
end
