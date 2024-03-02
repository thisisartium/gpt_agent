defmodule GptAgent.Events.ToolCallOutputSubmissionFailed do
  @moduledoc """
  The GPT Assistant has recorded a tool call output
  """

  use GptAgent.Types
  alias GptAgent.Types

  @derive Jason.Encoder
  typedstruct enforce: true do
    field :thread_id, Types.thread_id()
    field :run_id, Types.run_id()
  end
end
