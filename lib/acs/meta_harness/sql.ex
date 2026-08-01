defmodule Acs.MetaHarness.SQL do
  @moduledoc false
  # Raw SQL helpers for Meta-Harness (SQLite locally, Postgres/Neon in prod).

  def postgres? do
    Application.get_env(:steward_acs, :repo_adapter) == Ecto.Adapters.Postgres or
      match?("postgres" <> _, System.get_env("DATABASE_URL") || "")
  end

  @doc """
  Rewrite SQLite-style `?1` placeholders to Postgres `$1`.
  Bare `?` (no index) is left alone — use `placeholders/1` for those.
  """
  def adapt(sql) when is_binary(sql) do
    if postgres?() do
      Regex.replace(~r/\?(\d+)/, sql, fn _, n -> "$#{n}" end)
    else
      sql
    end
  end

  @doc "Comma-separated placeholders for an INSERT VALUES clause."
  def placeholders(count) when is_integer(count) and count > 0 do
    if postgres?() do
      Enum.map_join(1..count, ", ", &"$#{&1}")
    else
      List.duplicate("?", count) |> Enum.join(", ")
    end
  end
end
