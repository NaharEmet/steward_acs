defmodule Acs.Repo.Migrations.AddOrgToAllTables do
  use Ecto.Migration

  def change do
    # Rename cluster → org on 5 tables that already have cluster
    rename table(:acs_tasks), :cluster, to: :org
    rename table(:acs_file_locks), :cluster, to: :org
    rename table(:acs_agent_status), :cluster, to: :org
    rename table(:acs_developer_api_keys), :cluster, to: :org

    # log_entries also has cluster column — rename
    rename table(:log_entries), :cluster, to: :org

    # Add org column to 6 tables that lack it
    alter table(:acs_memories) do
      add :org, :string, default: "default"
    end

    alter table(:tool_requests) do
      add :org, :string, default: "default"
    end

    alter table(:task_completion_feedback) do
      add :org, :string, default: "default"
    end

    alter table(:acs_tool_operations) do
      add :org, :string, default: "default"
    end

    alter table(:users) do
      add :org, :string, default: "default"
    end

    alter table(:users_tokens) do
      add :org, :string, default: "default"
    end

    # Update indexes — rename cluster indexes and add org indexes
    drop index(:acs_tasks, [:cluster], name: :acs_tasks_cluster_index)
    create index(:acs_tasks, [:org], name: :acs_tasks_org_index)

    drop index(:acs_file_locks, [:cluster], name: :acs_file_locks_cluster_index)
    create index(:acs_file_locks, [:org], name: :acs_file_locks_org_index)

    drop index(:acs_agent_status, [:cluster], name: :acs_agent_status_cluster_index)
    create index(:acs_agent_status, [:org], name: :acs_agent_status_org_index)

    drop index(:acs_developer_api_keys, [:cluster], name: :acs_dev_keys_cluster_index)
    create index(:acs_developer_api_keys, [:org], name: :acs_dev_keys_org_index)

    drop index(:log_entries, [:cluster, :timestamp], name: :log_entries_cluster_timestamp_index)
    create index(:log_entries, [:org, :timestamp], name: :log_entries_org_timestamp_index)

    # New indexes for tables that just got org
    create index(:acs_memories, [:org], name: :acs_memories_org_index)
    create index(:users, [:org], name: :users_org_index)
    create index(:users_tokens, [:org], name: :users_tokens_org_index)
  end
end
