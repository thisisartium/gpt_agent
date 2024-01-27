defmodule GptAgent.Types.UserMessage do
  @moduledoc """
  Represents a message sent by a user to the OpenAI GPT assistant
  """

  use GptAgent.Types
  alias GptAgent.Types

  typedstruct do
    field :content, Types.nonblank_string()
    field :file_ids, list(Types.file_id()) | nil
    field :metadata, Types.message_metadata() | nil
  end

  defimpl Jason.Encoder do
    def encode(%GptAgent.Types.UserMessage{content: content, file_ids: nil, metadata: nil}, opts) do
      map = %{
        role: "user",
        content: content
      }

      Jason.Encoder.encode(map, opts)
    end
  end
end
