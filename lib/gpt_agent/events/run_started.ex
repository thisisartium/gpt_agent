defmodule GptAgent.Events.RunStarted do
  @moduledoc """
  An OpenAI Assistants run was started
  """
  use TypedStruct

  typedstruct do
    field :id, binary(), enforce: true
    field :thread_id, binary(), enforce: true
    field :assistant_id, binary(), enforce: true
  end
end
