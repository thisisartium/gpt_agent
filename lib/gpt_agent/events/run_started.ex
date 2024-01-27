defmodule GptAgent.Events.RunStarted do
  @moduledoc """
  An OpenAI Assistants run was started
  """

  use GptAgent.Types
  alias GptAgent.Types

  typedstruct enforce: true do
    field :id, Types.run_id()
    field :thread_id, Types.thread_id()
    field :assistant_id, Types.assistant_id()
  end
end
