defmodule GptAgent.Events.ToolCallOutputRecorded do
  @moduledoc """
  The GPT Assistant has recorded a tool call output
  """

  use TypedStruct

  typedstruct do
    field :id, binary(), enforce: true
    field :thread_id, binary(), enforce: true
    field :run_id, binary(), enforce: true
    field :name, String.t(), enforce: true
    field :output, binary(), enforce: true
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
