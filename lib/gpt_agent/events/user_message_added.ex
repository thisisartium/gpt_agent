defmodule GptAgent.Events.UserMessageAdded do
  @moduledoc """
  An OpenAI Assistants user message was added to a thread
  """

  use GptAgent.Types
  alias GptAgent.Types

  typedstruct enforce: true do
    field :id, Types.message_id()
    field :thread_id, Types.thread_id()
    field :content, Types.nonblank_string()
  end
end
