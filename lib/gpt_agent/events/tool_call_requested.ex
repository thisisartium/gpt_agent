defmodule GptAgent.Events.ToolCallRequested do
  @moduledoc """
  The GPT Assistant has requested a tool call
  """

  use TypedStruct

  typedstruct do
    field :id, binary(), enforce: true
    field :thread_id, binary(), enforce: true
    field :run_id, binary(), enforce: true
    field :name, String.t(), enforce: true
    field :arguments, map(), enforce: true
  end
end
