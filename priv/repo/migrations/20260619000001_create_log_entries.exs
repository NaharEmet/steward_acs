defmodule Acs.Repo.Migrations.CreateLogEntries do
  use Ecto.Migration

  def change do
    create table(:log_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :timestamp, :utc_datetime_usec, null: false
      add :level, :string, null: false
      add :service, :string
      add :component, :string
      add :message, :text, null: false
      add :metadata, :text
      add :workflow_id, :string
      add :execution_id, :string
      add :cluster, :string
      timestamps(type: :utc_datetime)
    end

    create index(:log_entries, [:timestamp], name: :log_entries_timestamp_index)
    create index(:log_entries, [:level, :timestamp], name: :log_entries_level_timestamp_index)
    create index(:log_entries, [:cluster, :timestamp], name: :log_entries_cluster_timestamp_index)
    create index(:log_entries, [:workflow_id], name: :log_entries_workflow_id_index)
    create index(:log_entries, [:execution_id], name: :log_entries_execution_id_index)
  end
end
