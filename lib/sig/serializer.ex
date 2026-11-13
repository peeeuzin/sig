defmodule Sig.Serializer do
  @moduledoc """
  Converts Elixir terms into JSON-safe values for storage in PostgreSQL JSONB
  columns.

  Node results and errors go through this module before being persisted, which
  is why nodes downstream see string keys and string values where atoms were
  returned.
  """

  @doc """
  Recursively converts a term into a JSON-safe value.

    * map keys become strings (structs are converted to plain maps);
    * atoms other than `nil`, `true` and `false` become strings;
    * tuples become lists;
    * other values are returned unchanged.

  ## Examples

      iex> Sig.Serializer.serialize(%{status: :ok, pair: {1, :a}})
      %{"status" => "ok", "pair" => [1, "a"]}
  """
  @spec serialize(term()) :: term()
  def serialize(term) when is_map(term) do
    term
    |> Map.drop([:__struct__])
    |> Enum.map(fn {k, v} -> {to_string(k), serialize(v)} end)
    |> Map.new()
  end

  def serialize(term) when is_list(term) do
    Enum.map(term, &serialize/1)
  end

  def serialize(term) when is_atom(term) and not is_nil(term) and not is_boolean(term) do
    to_string(term)
  end

  def serialize(term) when is_tuple(term) do
    term |> Tuple.to_list() |> serialize()
  end

  def serialize(term), do: term

  @doc """
  Serializes a node result, wrapping non-map values as `%{"value" => value}`
  so that every stored result is a JSON object.

  ## Examples

      iex> Sig.Serializer.wrap_result(%{total: 3})
      %{"total" => 3}

      iex> Sig.Serializer.wrap_result(:done)
      %{"value" => "done"}
  """
  @spec wrap_result(term()) :: map()
  def wrap_result(result) when is_map(result) do
    serialize(result)
  end

  def wrap_result(result) do
    %{"value" => serialize(result)}
  end

  @doc """
  Reverses `wrap_result/1`: returns the inner value of a `%{"value" => value}`
  map, or the map itself otherwise.

  ## Examples

      iex> Sig.Serializer.unwrap_result(%{"value" => 42})
      42

      iex> Sig.Serializer.unwrap_result(%{"total" => 3})
      %{"total" => 3}
  """
  @spec unwrap_result(map()) :: term()
  def unwrap_result(%{"value" => val}) when map_size(%{"value" => val}) == 1, do: val
  def unwrap_result(result), do: result
end
