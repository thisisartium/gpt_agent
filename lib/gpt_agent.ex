defmodule GptAgent do
  @moduledoc """
  Provides a GPT conversation agent
  """

  use GenServer
  use TypedStruct

  alias GptAgent.Events.{ThreadCreated, UserMessageAdded}
  alias GptAgent.Values.NonblankString

  typedstruct do
    field :pid, pid(), enforce: true
    field :callback_handler, pid(), enforce: true
    field :thread_id, binary() | nil
  end

  defp continue(state, continue_arg), do: {:ok, state, {:continue, continue_arg}}
  defp noreply(state), do: {:noreply, state}

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
    |> continue(:create_thread)
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

  def handle_cast({:add_user_message, message}, state) do
    {:ok, message} = NonblankString.new(message)

    {:ok, %{body: %{"id" => id}}} =
      OpenAiClient.post("/v1/threads/#{state.thread_id}/messages", json: message)

    state
    |> send_callback(%UserMessageAdded{
      id: id,
      thread_id: state.thread_id,
      content: message
    })
    |> noreply()
  end

  @doc """
  Starts the GPT Agent
  """
  @spec start_link(pid(), binary(), binary() | nil) :: {:ok, pid()} | {:error, reason :: term()}
  def start_link(callback_handler, _assistant_id, thread_id \\ nil)
      when is_pid(callback_handler) do
    GenServer.start_link(__MODULE__, callback_handler: callback_handler, thread_id: thread_id)
  end

  def add_user_message(pid, message) do
    GenServer.cast(pid, {:add_user_message, message})
  end
end
