defmodule Acs.MetaHarness.SQLTest do
  use ExUnit.Case, async: true

  alias Acs.MetaHarness.SQL

  setup do
    original = Application.get_env(:steward_acs, :repo_adapter)

    on_exit(fn ->
      if original,
        do: Application.put_env(:steward_acs, :repo_adapter, original),
        else: Application.delete_env(:steward_acs, :repo_adapter)
    end)

    :ok
  end

  test "adapt rewrites ?N to $N on Postgres" do
    Application.put_env(:steward_acs, :repo_adapter, Ecto.Adapters.Postgres)

    assert SQL.adapt("WHERE created_at >= ?1 AND created_at <= ?2") ==
             "WHERE created_at >= $1 AND created_at <= $2"
  end

  test "adapt leaves SQLite placeholders alone" do
    Application.put_env(:steward_acs, :repo_adapter, Ecto.Adapters.SQLite3)

    assert SQL.adapt("WHERE created_at >= ?1") == "WHERE created_at >= ?1"
  end

  test "placeholders are $N on Postgres and ? on SQLite" do
    Application.put_env(:steward_acs, :repo_adapter, Ecto.Adapters.Postgres)
    assert SQL.placeholders(3) == "$1, $2, $3"

    Application.put_env(:steward_acs, :repo_adapter, Ecto.Adapters.SQLite3)
    assert SQL.placeholders(3) == "?, ?, ?"
  end
end
