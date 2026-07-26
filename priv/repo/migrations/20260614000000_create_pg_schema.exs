defmodule Acs.Repo.Migrations.CreatePgSchema do
  use Ecto.Migration

  # Historical "squash" for greenfield Postgres. When migrations run in order,
  # earlier files already create these tables — recreating them fails with
  # duplicate_table. Keep as a no-op so schema_migrations can advance.
  def change do
    :ok
  end
end
