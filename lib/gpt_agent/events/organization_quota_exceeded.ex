defmodule GptAgent.Events.OrganizationQuotaExceeded do
  @moduledoc """
  An OpenAI Assistants run failed due to the organization running out of tokens
  """

  use GptAgent.Types
  alias GptAgent.Types

  typedstruct enforce: true do
    field :run_id, Types.run_id()
    field :thread_id, Types.thread_id()
    field :assistant_id, Types.assistant_id()
  end
end
