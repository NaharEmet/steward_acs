defmodule Acs.Repo.Migrations.AddFirstAndLastNameToUsers do
  use Ecto.Migration

  # Postgres supports `IF NOT EXISTS`; SQLite does not (CI/dev uses SQLite).
  def up do
    case repo().__adapter__() do
      Ecto.Adapters.Postgres ->
        execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS first_name TEXT")
        execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS last_name TEXT")

      _ ->
        alter table(:users) do
          add :first_name, :string
          add :last_name, :string
        end
    end
  end

  def down do
    alter table(:users) do
      remove :first_name
      remove :last_name
    end
  end
end
