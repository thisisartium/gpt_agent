defmodule GptAgent.Supervisor do
  @moduledoc """
  Manages the GptAgent processes, ensuring that there is only one process per thread-id.
  """

  use DynamicSupervisor

  require Logger

  def start_link(init_arg) do
    log_level =
      Application.get_env(:gpt_agent, :log_level) || Application.get_env(:logger, :level) ||
        :warning

    Logger.put_module_level(__MODULE__, log_level)
    Logger.put_module_level(GptAgent, log_level)
    {:ok, pid} = DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
    Logger.info("Started GptAgent.Supervisor with pid #{inspect(pid)}")

    result =
      DynamicSupervisor.start_child(pid, {Registry, [keys: :unique, name: GptAgent.Registry]})

    Logger.info("Started GptAgent.Registry: #{inspect(result)}")
    result = DynamicSupervisor.start_child(pid, {Phoenix.PubSub, [name: GptAgent.PubSub]})
    Logger.info("Started GptAgent.PubSub: #{inspect(result)}")
    {:ok, pid}
  end

  @impl DynamicSupervisor
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
