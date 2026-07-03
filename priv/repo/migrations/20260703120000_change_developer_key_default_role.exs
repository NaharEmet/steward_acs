defmodule Acs.Repo.Migrations.ChangeDeveloperKeyDefaultRole do
  use Ecto.Migration

  def up do
    if postgres?() do
      alter table(:acs_developer_api_keys) do
        modify :role, :string, default: "collaborator"
      end
    end
  end

  def down do
    if postgres?() do
      alter table(:acs_developer_api_keys) do
        modify :role, :string, default: "admin"
      end
    end
  end

  defp postgres? do
    Application.get_env(:steward_acs, :repo_adapter, Ecto.Adapters.SQLite3) ==
      Ecto.Adapters.Postgres
  end
end
