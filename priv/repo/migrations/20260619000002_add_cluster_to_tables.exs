defmodule Acs.Repo.Migrations.AddClusterToTables do
  use Ecto.Migration

  @disable_ddl_transaction true

  def change do
    alter table(:acs_tasks) do
      add :cluster, :string, default: "default"
    end

    alter table(:acs_file_locks) do
      add :cluster, :string, default: "default"
    end

    alter table(:acs_agent_status) do
      add :cluster, :string, default: "default"
    end

    create index(:acs_tasks, [:cluster], name: :acs_tasks_cluster_index)
    create index(:acs_file_locks, [:cluster], name: :acs_file_locks_cluster_index)
    create index(:acs_agent_status, [:cluster], name: :acs_agent_status_cluster_index)
  end
end
