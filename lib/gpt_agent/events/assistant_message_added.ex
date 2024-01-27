defmodule GptAgent.Events.AssistantMessageAdded do
  @moduledoc """
  An OpenAI Assistants assistant message was added to a thread
  """

  use GptAgent.Types
  alias GptAgent.Types

  typedstruct enforce: true do
    field :message_id, Types.message_id()
    field :thread_id, Types.thread_id()
    field :run_id, Types.run_id()
    field :assistant_id, Types.assistant_id()
    field :content, Types.nonblank_string()
  end
end
