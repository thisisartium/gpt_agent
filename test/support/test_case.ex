defmodule GptAgent.TestCase do
  @moduledoc """
  This module provides test case template for GptAgent tests.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import GptAgent.TestCase
    end
  end
end
