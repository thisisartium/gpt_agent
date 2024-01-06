defmodule GptAgent.Events.AssistantMessageAdded do
  @moduledoc """
  An OpenAI Assistants assistant message was added to a thread
  """

  use TypedStruct

  typedstruct do
    field :message_id, binary(), enforce: true
    field :thread_id, binary(), enforce: true
    field :run_id, binary(), enforce: true
    field :assistant_id, binary(), enforce: true
    field :content, String.t(), enforce: true
  end
end
