defmodule GptAgent.TestCase do
  @moduledoc """
  Base test case template for the entire GptAgent application

  This case template includes setup and helper functions that are applicable to
  all tests of the application.
  """

  use ExUnit.CaseTemplate
  use ExUnitProperties

  using do
    quote do
      use ExUnitProperties

      import AssertMatch, only: [assert_match: 2]
      import GptAgent.TestCase
    end
  end

  @doc """
  `StreamData` generator for UUIDs
  """
  def uuid do
    StreamData.frequency([
      {3,
       StreamData.map(integer(), fn _n ->
         UUID.uuid4()
       end)},
      {1,
       StreamData.map(integer(), fn _n ->
         UUID.uuid4() |> UUID.string_to_binary!()
       end)}
    ])
  end

  def term_other_than_uuid do
    StreamData.filter(term(), fn x -> !is_uuid?(x) end)
  end

  def is_uuid?(value) do
    case UUID.info(value) do
      {:ok, _} -> true
      _ -> false
    end
  end

  def url do
    StreamData.map(integer(), fn _n ->
      Faker.Internet.url()
    end)
  end

  def term_other_than_url do
    StreamData.filter(term(), fn x ->
      !is_binary(x) || !is_url(x)
    end)
  end

  defp is_url(data) do
    case URI.new(data) do
      {:ok, _uri} -> true
      _ -> false
    end
  rescue
    # why? Because the URI library will throw function clause errors on certain
    # binaries instead of just returning a gosh-darned {:error, _} tuple
    _ -> false
  end

  def nonblank_string do
    StreamData.string(:printable)
    |> StreamData.filter(&(String.trim(&1) != ""))
  end

  def term_other_than_nonblank_string do
    StreamData.filter(term(), fn x ->
      if is_binary(x) do
        x |> String.trim() |> String.length() == 0
      else
        true
      end
    end)
  end
end
