defmodule GptAgent.Values.NonblankString do
  @moduledoc """
  A message that a user has sent to the GPT agent
  """

  use GptAgent.Value

  type(String.t())

  validate_with(fn
    value when is_binary(value) ->
      case String.trim(value) do
        "" -> {:error, "must be a nonblank string"}
        _ -> :ok
      end

    _ ->
      {:error, "must be a nonblank string"}
  end)

  defimpl Jason.Encoder do
    def encode(%{value: value}, opts) do
      %{role: :user, content: value}
      |> Jason.Encoder.encode(opts)
    end
  end
end
