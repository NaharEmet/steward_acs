defmodule Acs.Ecto.JsonMap do
  @moduledoc """
  Map stored as JSON text.

  SQLite's `:map` type already dumps to text; Postgrex `:map` expects jsonb.
  Our `log_entries.metadata` column is `:text` on both adapters, so we dump
  explicitly to a JSON string.
  """
  use Ecto.Type

  def type, do: :string

  def cast(nil), do: {:ok, %{}}
  def cast(map) when is_map(map), do: {:ok, map}

  def cast(bin) when is_binary(bin) do
    case Jason.decode(bin) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> :error
    end
  end

  def cast(_), do: :error

  def load(nil), do: {:ok, %{}}
  def load(map) when is_map(map), do: {:ok, map}

  def load(bin) when is_binary(bin) do
    case Jason.decode(bin) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:ok, %{}}
    end
  end

  def load(_), do: :error

  def dump(nil), do: {:ok, "{}"}
  def dump(map) when is_map(map), do: {:ok, Jason.encode!(map)}
  def dump(bin) when is_binary(bin), do: {:ok, bin}
  def dump(_), do: :error
end
