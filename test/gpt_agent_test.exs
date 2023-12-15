defmodule GptAgentTest do
  use ExUnit.Case
  doctest GptAgent

  test "greets the world" do
    assert GptAgent.hello() == :world
  end
end
