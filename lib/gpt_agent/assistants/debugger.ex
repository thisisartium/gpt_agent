defmodule GptAgent.Assistants.Debugger do
  def start(thread_id) do
    Task.async(fn ->
      Phoenix.PubSub.subscribe(GptAgent.PubSub, "gpt_agent:#{thread_id}")
      loop()
    end)
  end

  defp loop do
    receive do
      message ->
        IO.inspect(message)
        loop()
    end
  end
end
