defmodule Acs.Repo.Migrations.CreateOrgsTable do
  use Ecto.Migration

  def change do
    create table(:orgs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :subdomain, :string
      add :plan, :string, default: "free"
      timestamps(type: :utc_datetime)
    end

    create unique_index(:orgs, [:slug], name: :orgs_slug_unique)
    create unique_index(:orgs, [:subdomain], name: :orgs_subdomain_unique)
  end
end
