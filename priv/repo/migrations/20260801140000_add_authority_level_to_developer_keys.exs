defmodule Acs.Repo.Migrations.AddAuthorityLevelToDeveloperKeys do
  use Ecto.Migration

  def up do
    alter table(:acs_developer_api_keys) do
      add :authority_level_slug, :string, null: false, default: "standard"
    end
  end

  def down do
    alter table(:acs_developer_api_keys) do
      remove :authority_level_slug
    end
  end
end
