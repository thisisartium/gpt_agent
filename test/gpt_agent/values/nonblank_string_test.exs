defmodule GptAgent.Values.NonblankStringTest do
  @moduledoc false

  use GptAgent.TestCase, async: true

  alias GptAgent.Values.NonblankString

  test "a non-blank string is valid" do
    check all(value <- nonblank_string()) do
      assert {:ok, %NonblankString{value: ^value}} = NonblankString.new(value)
    end
  end

  test "blank strings are invalid" do
    assert {:error, "must be a nonblank string"} = NonblankString.new("")
    assert {:error, "must be a nonblank string"} = NonblankString.new(" ")
    assert {:error, "must be a nonblank string"} = NonblankString.new(" \n\t ")
  end

  test "all other values are invalid" do
    check all(value <- term_other_than_nonblank_string()) do
      assert {:error, "must be a nonblank string"} = NonblankString.new(value)
    end
  end
end
