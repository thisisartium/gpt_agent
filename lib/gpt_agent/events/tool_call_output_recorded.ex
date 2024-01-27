defmodule GptAgent.Events.ToolCallOutputRecorded do
  @moduledoc """
  The GPT Assistant has recorded a tool call output
  """

  use GptAgent.Types
  alias GptAgent.Types

  typedstruct enforce: true do
    field :id, Types.tool_call_id()
    field :thread_id, Types.thread_id()
    field :run_id, Types.run_id()
    field :name, Types.tool_name()
    field :output, Types.tool_output()
  end

  defimpl Jason.Encoder do
    def encode(event, opts) do
      Jason.Encoder.encode(
        %{
          tool_call_id: event.id,
          output: event.output
        },
        opts
      )
    end
  end
end
