defmodule GptAgentTest do
  use ExUnit.Case
  doctest GptAgent

  describe "start_link/0" do
    test "starts the agent" do
      assert {:ok, pid} = GptAgent.start_link()
      assert Process.alive?(pid)
    end
  end
end
