defmodule Acs.Repo.Migrations.CreateAcsMemories do
  use Ecto.Migration

  def change do
    create table(:acs_memories, primary_key: false) do
      add :id, :string, primary_key: true
      add :kind, :string, null: false
      add :status, :string, default: "proposed", null: false
      add :title, :string, null: false
      add :summary, :text
      add :content, :text
      add :scope_path, :string, null: false
      add :importance, :integer, default: 3
      add :tags_json, :text
      add :triggers_json, :text
      add :failure_modes_json, :text
      add :related_memories_json, :text
      add :verification_json, :text
      add :revalidation_json, :text
      add :created_by_json, :text
      add :created_by_agent, :string
      add :parse_error, :text
      add :file_path, :string
      add :created_at, :utc_datetime
      add :updated_at, :utc_datetime
    end

    create index(:acs_memories, [:kind])
    create index(:acs_memories, [:status])
    create index(:acs_memories, [:scope_path])
    create index(:acs_memories, [:kind, :status])
  end
end
