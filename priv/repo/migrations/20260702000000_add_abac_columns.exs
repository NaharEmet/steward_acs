defmodule Acs.Repo.Migrations.AddAbacColumns do
  use Ecto.Migration

  def up do
    alter table(:acs_memories) do
      add :team, :string, null: true
      add :project, :string, null: true
      add :visibility, :string, null: true
    end

    alter table(:acs_developer_api_keys) do
      add :allowed_teams_json, :string, null: true
      add :allowed_projects_json, :string, null: true
    end
  end

  def down do
    alter table(:acs_memories) do
      remove :team
      remove :project
      remove :visibility
    end

    alter table(:acs_developer_api_keys) do
      remove :allowed_teams_json
      remove :allowed_projects_json
    end
  end
end
