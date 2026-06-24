defmodule Acs.DataCase do
  @moduledoc """
  Test case template for ACS tests requiring database access.

  Sets up the SQL sandbox for SQLite to ensure each test runs in
  an isolated transaction that is rolled back after the test completes.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Acs.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Acs.DataCase
    end
  end

  setup tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Acs.Repo, shared: not tags[:async])

    unless tags[:async] do
      Ecto.Adapters.SQL.Sandbox.mode(Acs.Repo, {:shared, self()})
    end

    :ok
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
