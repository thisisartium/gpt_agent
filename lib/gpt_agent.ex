defmodule GptAgent do
  @moduledoc """
  Provides a GPT conversation agent
  """

  use GenServer

  @doc """
  Initializes the GPT Agent
  """
  @spec init(any()) :: {:ok, any()}
  def init(init_arg) do
    {:ok, init_arg}
  end

  @doc """
  Starts the GPT Agent
  """
  @spec start_link() :: {:ok, pid()} | {:error, reason :: term()}
  def start_link do
    GenServer.start_link(__MODULE__, nil)
  end
end
