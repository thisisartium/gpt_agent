defmodule GptAgent.Events.UserMessageAdded do
  @moduledoc """
  An OpenAI Assistants user message was added to a thread
  """

  alias GptAgent.Values.NonblankString

  use TypedStruct

  typedstruct do
    field :id, binary(), enforce: true
    field :thread_id, binary(), enforce: true
    field :content, NonblankString.t(), enforce: true
  end
end
