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
    field :prompt_tokens, non_neg_integer()
    field :completion_tokens, non_neg_integer()
    field :total_tokens, non_neg_integer()
  end
end
