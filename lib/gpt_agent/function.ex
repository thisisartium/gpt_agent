defmodule GptAgent.Function do
  @moduledoc """
  Represents a function that can be called by the OpenAI GPT assistant
  """

  use GptAgent.Types
  alias GptAgent.Types

  defmodule Parameter do
    @moduledoc """
    Represents a parameter of a function that can be called by the OpenAI GPT assistant
    """

    use GptAgent.Types
    alias GptAgent.Types

    @type type :: :string | :number | :integer | :object | :array | :boolean | :null

    typedstruct do
      field :name, Types.nonblank_string(), enforce: true
      field :description, Types.nonblank_string(), enforce: true
      field :type, type() | list(type()), enforce: true
      field :required, boolean(), default: false
      field :properties, list(t()) | nil
      field :enum, [Types.nonblank_string() | number()] | nil
    end

    precond t: &validate_parameter/1

    defp validate_parameter(%Parameter{type: :object, properties: properties})
         when is_nil(properties) or properties == [] do
      {:error, "Object parameters must have properties"}
    end

    defp validate_parameter(%Parameter{}), do: :ok

    defimpl Jason.Encoder do
      def encode(
            %Parameter{
              name: name,
              description: description,
              type: type,
              enum: enum,
              properties: properties
            },
            opts
          ) do
        map = %{
          name: name,
          description: description,
          type: type
        }

        map = if enum != nil, do: Map.put(map, :enum, enum), else: map
        map = encode_object_properties(map, properties)
        Jason.Encoder.encode(map, opts)
      end

      defp encode_object_properties(%{type: :object} = map, properties) do
        {properties, required} =
          Enum.reduce(properties, {%{}, []}, fn property, acc ->
            {properties, required} = acc
            properties = Map.put(properties, property.name, property)
            required = if property.required, do: [property.name | required], else: required
            {properties, required}
          end)

        map
        |> Map.put(:properties, properties)
        |> Map.put(:required, required)
      end

      defp encode_object_properties(map, _properties), do: map
    end
  end

  typedstruct do
    field :name, Types.tool_name(), enforce: true
    field :description, Types.nonblank_string(), enforce: true
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
              |> Enum.map(fn parameter -> parameter.name end)
          }
        }
      }

      Jason.Encoder.encode(map, opts)
    end
  end
end
