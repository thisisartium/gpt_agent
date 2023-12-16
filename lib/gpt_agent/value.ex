defmodule GptAgent.Value do
  @moduledoc """
  A module that provides a macro to define a new type and its validation.
  """

  @doc """
  Macro to use GptAgent.Value in the current module.

  ## Examples

      defmodule MyModule do
        use GptAgent.Value
      end
  """
  defmacro __using__(_opts) do
    quote do
      require GptAgent.Value
      import GptAgent.Value
    end
  end

  @doc """
  Macro to define a new type.

  ## Examples

      defmodule MyType do
        use GptAgent.Value
        type String.t()
      end
  """
  @spec type(atom()) :: Macro.t()
  defmacro type(type) do
    quote do
      use TypedStruct

      typedstruct do
        field :value, unquote(type), enforce: true
      end

      @doc """
      Creates a new instance of the type.

      The function validates the value and returns a new struct if the value is valid.
      If the value is invalid, it returns an error tuple with the error message.

      ## Params

      - `value`: The value to be validated and set in the struct.

      ## Examples

          iex> MyType.new("valid value")
          %MyType{value: "valid value"}

          iex> MyType.new("invalid value")
          {:error, "error message"}

      """
      @spec new(any()) :: {:ok, t()} | {:error, String.t()}
      def new(value) do
        case validate(value) do
          :ok ->
            {:ok, %__MODULE__{value: value}}

          {:error, error} ->
            {:error, error}
        end
      end
    end
  end

  @doc """
  Macro to define a validation function for the type.

  ## Examples

      defmodule MyType do
        use GptAgent.Value
        type String.t()
        validate_with fn
          value when is_binary(value) ->
            case String.trim(value) do
              "" -> {:error, "must be a nonblank string"}
              _ -> :ok
            end
        end
      end
  """
  @spec validate_with(Macro.t()) :: Macro.t()
  defmacro validate_with(validate_with) do
    quote do
      defp validate(value) do
        unquote(validate_with).(value)
      end
    end
  end
end
