defmodule GptAgent.Events.RateLimited do
  @moduledoc """
  An OpenAI Assistants run failed due to rate limiting
  """

  use GptAgent.Types
  alias GptAgent.Types

  typedstruct enforce: true do
    field :run_id, Types.run_id()
    field :thread_id, Types.thread_id()
    field :assistant_id, Types.assistant_id()
    field :retries_remaining, non_neg_integer()
  end
end
