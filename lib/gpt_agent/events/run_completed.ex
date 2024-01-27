defmodule GptAgent.Events.RunCompleted do
  @moduledoc """
  An OpenAI Assistants run was completed
  """

  use GptAgent.Types
  alias GptAgent.Types

  typedstruct enforce: true do
    field :id, Types.run_id()
    field :thread_id, Types.thread_id()
    field :assistant_id, Types.assistant_id()
  end
end
