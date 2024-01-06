defmodule GptAgent.Assistants.Debugger do
  @moduledoc false

  @doc false
  def start(thread_id) do
    Task.async(fn ->
      Phoenix.PubSub.subscribe(GptAgent.PubSub, "gpt_agent:#{thread_id}")
      loop()
    end)
  end

  defp loop do
    receive do
      message ->
        # credo:disable-for-next-line
        IO.inspect(message)
        loop()
    end
  end
end
