defmodule GptAgent.Events.ThreadCreated do
  @moduledoc """
  An OpenAI Assistants thread was created
  """

  use TypedStruct

  typedstruct do
    field :id, String.t(), enforce: true
  end
end
