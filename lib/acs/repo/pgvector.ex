defmodule Acs.Repo.Pgvector do
  @moduledoc false
  # Shared Postgres vs SQLite helpers for embedding tables.

  def enabled?(repo \\ Acs.Repo), do: repo.__adapter__() == Ecto.Adapters.Postgres

  def encode(embedding) when is_list(embedding), do: Jason.encode!(embedding)

  def dimensions, do: Acs.Memory.Embedding.dimensions()

  def to_float(%Decimal{} = d), do: Decimal.to_float(d)
  def to_float(n) when is_number(n), do: n * 1.0
  def to_float(bin) when is_binary(bin), do: String.to_float(bin)
  def to_float(_), do: 0.0

  def org_filter(options) do
    case Keyword.get(options, :org) do
      org when is_binary(org) and org != "" -> org
      _ -> if Acs.Org.multi_tenant?(), do: Acs.Org.current(), else: nil
    end
  end

  def resolve_embedding(query, opts) do
    case Keyword.get(opts, :embedding) do
      emb when is_list(emb) and emb != [] -> {:ok, emb}
      _ -> Acs.Memory.Embedding.embed_text(query)
    end
  end
end
