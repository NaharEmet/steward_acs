defmodule Acs.Repo.Migrations.CreateAcsTables do
  use Ecto.Migration

  def change do
    create table(:acs_agent_status, primary_key: false) do
      add :agent_id, :string, primary_key: true
      add :current_task_id, :binary_id
      add :purpose, :string
      timestamps(type: :utc_datetime)
    end

    create table(:acs_tasks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string
      add :description, :string
      add :status, :string, default: "todo"
      add :created_by_agent, :string
      add :locked_by_agent, :string
      add :locked_at, :utc_datetime
      add :auto_release_at, :utc_datetime
      add :event_count, :integer, default: 1
      timestamps(type: :utc_datetime)
    end

    create table(:acs_file_locks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :file_path, :string
      add :locked_by_agent, :string
      add :locked_at, :utc_datetime
      add :auto_release_at, :utc_datetime
      add :task_id, references(:acs_tasks, type: :binary_id, on_delete: :delete_all)
      timestamps(type: :utc_datetime)
    end

    create index(:acs_file_locks, [:file_path], unique: true, name: :acs_file_locks_file_path_index)
  end
end