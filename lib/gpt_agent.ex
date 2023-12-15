defmodule GptAgent do
  @moduledoc """
  Provides a GPT conversation agent
  """

  use GenServer

  def init(init_arg) do
    {:ok, init_arg}
  end

  def start_link do
    GenServer.start_link(__MODULE__, nil)
  end
end
