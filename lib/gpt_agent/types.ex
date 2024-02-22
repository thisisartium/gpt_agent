defmodule GptAgent.Types do
  @moduledoc """
  Defines the generic types used throughout the library and provides common validation for those types.

  You can `use GptAgent.Types` in other modules to import the validation
  functions and automatically set up both `TypedStruct` and `Domo` for your
  module.
  """

  import Domo, only: [precond: 1]

  @type nonblank_string() :: String.t()
  precond nonblank_string: &validate_nonblank_string/1

  @type assistant_id() :: nonblank_string()
  @type message_id() :: nonblank_string()
  @type run_id() :: nonblank_string()
  @type thread_id() :: nonblank_string()
  @type file_id() :: nonblank_string()

  @type run_error_code() :: nonblank_string()
  @type run_error_message() :: nonblank_string()

  @type message_metadata() :: %{optional(String.t()) => Jason.Encoder.t()}
  precond message_metadata: &validate_message_metadata/1

  @type tool_output() :: nonblank_string()
  @type tool_name() :: nonblank_string()
  @type tool_call_id() :: nonblank_string()
  @type tool_arguments() :: %{optional(String.t()) => Jason.Encoder.t()}

  @type success() :: :ok
  @type success(t) :: {:ok, t}
  @type error(t) :: {:error, t}
  @type result(error_type) :: success() | error(error_type)
  @type result(success_type, error_type) :: success(success_type) | error(error_type)

  @doc """
  Validation for the `nonblank_string()` type
  """
  @spec validate_nonblank_string(String.t()) :: result(String.t())
  def validate_nonblank_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, "must not be blank"}
      _ -> :ok
    end
  end

  @doc """
  Validates metadata according to OpenAI documentation
  """
  @spec validate_message_metadata(message_metadata()) :: result(String.t())
  def validate_message_metadata(%{} = metadata) do
    if map_size(metadata) > 16 do
      {:error, "must have 16 or fewer keys"}
    else
      :ok
    end

    if Enum.any?(metadata, fn {key, value} ->
         String.length(key) > 64 || String.length(value) > 512
       end) do
      {:error, "keys must be 64 characters or fewer"}
    else
      :ok
    end
  end

  defmacro __using__(opts) do
    quote do
      use TypedStruct
      use Domo, unquote(opts)

      import GptAgent.Types
    end
  end
end
