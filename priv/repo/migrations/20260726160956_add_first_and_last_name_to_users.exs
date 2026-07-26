defmodule Acs.Repo.Migrations.AddFirstAndLastNameToUsers do
  use Ecto.Migration

  def up do
    execute """
    ALTER TABLE users ADD COLUMN IF NOT EXISTS first_name TEXT
    """
    execute """
    ALTER TABLE users ADD COLUMN IF NOT EXISTS last_name TEXT
    """
  end

  def down do
    alter table(:users) do
      remove :first_name
      remove :last_name
    end
  end
end
