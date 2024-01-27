defmodule GptAgent.Events.ToolCallRequested do
  @moduledoc """
  The GPT Assistant has requested a tool call
  """

  use GptAgent.Types
  alias GptAgent.Types

  typedstruct enforce: true do
    field :id, Types.tool_call_id()
    field :thread_id, Types.thread_id()
    field :run_id, Types.run_id()
    field :name, Types.tool_name()
    field :arguments, Types.tool_arguments()
  end
end
