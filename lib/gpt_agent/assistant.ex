defmodule GptAgent.Assistant do
  @moduledoc """
  Provides representation of the schema of an OpenAI GPT assistant
  """

  use GptAgent.Types
  alias GptAgent.Types

  typedstruct do
    field :id, Types.assistant_id(), enforce: true
    field :name, Types.nonblank_string(), enforce: true
    field :description, Types.nonblank_string(), enforce: true
    field :model, Types.nonblank_string(), enforce: true
    field :instructions, Types.nonblank_string(), enforce: true
    field :tools, [__MODULE__.Function.t()], default: []
    field :metadata, Types.assistant_metadata(), default: %{}
    field :temperature, Types.number(), default: 0.5
    field :top_p, Types.number(), default: 1.0
    field :response_format, Types.assistant_response_format(), default: "auto"
  end

  @doc """
  Creates a new `GptAgent.Assistant.Function`

  `params` are the same as the fields of `GptAgent.Assistant.Function`
  """
  @spec function(params :: keyword() | map()) :: __MODULE__.Function.t()
  def function(params), do: __MODULE__.Function.new!(params)

  @doc """
  Creates a new `GptAgent.Assistant.Function.Parameter`

  `params` are the same as the fields of `GptAgent.Assistant.Function.Parameter`
  """
  @spec parameter(params :: keyword() | map()) :: __MODULE__.Function.Parameter.t()
  def parameter(params), do: __MODULE__.Function.Parameter.new!(params)

  @doc """
  Creates a new `GptAgent.Assistant`

  `params` are passed unaltered to `GptAgent.Assistant.new!/1`; this macro is
  just a bit of syntactic sugar.
  """
  defmacro schema(params) do
    {id, params} = Keyword.pop(params, :id)

    quote do
      def assistant_id do
        unquote(id)
      end

      def schema do
        unquote(params)
        |> Enum.into(%{})
        |> Map.put(:id, assistant_id())
        |> GptAgent.Assistant.new!()
      end

      def publish do
        OpenAiClient.post("/v1/assistants/#{assistant_id()}", json: schema())
      end
    end
  end

  defimpl Jason.Encoder do
    def encode(assistant, opts) do
      map = %{
        name: assistant.name,
        description: assistant.description,
        model: assistant.model,
        instructions: assistant.instructions
      }

      map = if assistant.tools != [], do: Map.put(map, :tools, assistant.tools), else: map

      Jason.Encoder.encode(map, opts)
    end
  end

  defmodule Function do
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
end
