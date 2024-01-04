defmodule GptAgent.Supervisor do
  @moduledoc """
  Manages the GptAgent processes, ensuring that there is only one process per thread-id.
  """

  use DynamicSupervisor

  def start_link(init_arg) do
    {:ok, pid} = DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
    DynamicSupervisor.start_child(pid, {Registry, [keys: :unique, name: GptAgent.Registry]})
    {:ok, pid}
  end

  @impl DynamicSupervisor
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
