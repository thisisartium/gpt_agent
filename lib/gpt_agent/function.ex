defmodule GptAgent.Function do
  @moduledoc """
  Represents a function that can be called by the OpenAI GPT assistant
  """

  use TypedStruct

  defmodule Parameter do
    @moduledoc """
    Represents a parameter of a function that can be called by the OpenAI GPT assistant
    """

    use TypedStruct

    @type type :: :string | :integer

    typedstruct do
      field :name, String.t(), enforce: true
      field :description, String.t(), enforce: true
      field :type, type(), enforce: true
      field :required, boolean(), default: false
      field :enum, [binary() | number()] | nil
    end

    defimpl Jason.Encoder do
      def encode(
            %Parameter{
              name: name,
              description: description,
              type: type,
              enum: enum
            },
            opts
          ) do
        map = %{
          name: name,
          description: description,
          type: type
        }

        map = if enum != nil, do: Map.put(map, :enum, enum), else: map
        Jason.Encoder.encode(map, opts)
      end
    end
  end

  typedstruct do
    field :name, String.t(), enforce: true
    field :description, String.t(), enforce: true
    field :parameters, [Parameter.t()], default: []
  end

  defimpl Jason.Encoder do
    def encode(%{name: name, description: description, parameters: parameters}, opts) do
      map = %{
        type: "function",
        function: %{
          name: name,
          description: description,
          parameters: %{
            type: "object",
            properties:
              Enum.reduce(parameters, %{}, fn parameter, acc ->
                Map.put(acc, parameter.name, parameter)
              end),
            required:
              Enum.filter(parameters, fn parameter -> parameter.required end)
              |> Enum.map(fn parameter -> parameter.name end),
            additionalProperties: false
          }
        }
      }

      Jason.Encoder.encode(map, opts)
    end
  end
end
