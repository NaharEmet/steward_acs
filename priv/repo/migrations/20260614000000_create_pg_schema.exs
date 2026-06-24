defmodule Acs.Repo.Migrations.CreatePgSchema do
  use Ecto.Migration

  def change do
    # Only run on Postgres — SQLite dev/test uses individual migrations
    # On a fresh PG database, this single migration creates everything
    if repo().__adapter__() == Ecto.Adapters.Postgres do
      # === From 00000000000000_create_acs_tables.exs ===
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

      create index(:acs_file_locks, [:file_path],
               unique: true,
               name: :acs_file_locks_file_path_index
             )

      # === From 20260506214823_add_application_component_to_agent_status.exs ===
      alter table(:acs_agent_status) do
        add :application, :string
        add :component, :string
      end

      # === From 20260505000001_create_tool_requests.exs ===
      create table(:tool_requests, primary_key: false) do
        add :id, :binary_id, primary_key: true
        add :name, :string, null: false
        add :description, :string
        add :category, :string, default: "requested"
        add :definition, :text, null: false
        add :status, :string, default: "pending"
        add :agent_id, :string, null: false
        add :approved_by, :string
        timestamps(type: :utc_datetime)
      end

      # === From 20260507100000_create_acs_memories.exs ===
      create table(:acs_memories, primary_key: false) do
        add :id, :string, primary_key: true
        add :kind, :string
        add :status, :string
        add :title, :string
        add :summary, :text
        add :content, :text
        add :scope_path, :string
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
        timestamps(type: :utc_datetime)
      end

      create index(:acs_memories, [:kind])
      create index(:acs_memories, [:status])
      create index(:acs_memories, [:scope_path])
      create index(:acs_memories, [:kind, :status])

      # === From 20260513000001_add_memory_embeddings.exs ===
      create table(:memory_embeddings, primary_key: false) do
        add :memory_id, :string, primary_key: true
        add :embedding, :text, null: false
        add :updated_at, :naive_datetime, default: fragment("CURRENT_TIMESTAMP")
      end

      # === From 20260514104649_create_acs_tool_operations.exs ===
      # Note: use auto-increment integer PK
      create table(:acs_tool_operations) do
        add :agent_id, :string
        add :tool_name, :string, null: false
        add :execution_id, :string
        add :status, :string, default: "success"
        add :error_type, :string
        add :error_message, :text
        add :latency_ms, :integer
        add :execution_chain_id, :string
        add :sequence_order, :integer, default: 0
        add :attempt, :integer, default: 1
        add :tool_discovered, :boolean, default: false
        add :error_burst, :boolean, default: false
        add :params_hash, :string
        timestamps(type: :utc_datetime)
      end

      # === From 20260514150001_create_task_completion_feedback.exs ===
      create table(:task_completion_feedback) do
        add :task_id, references(:acs_tasks, type: :binary_id, on_delete: :delete_all)
        add :agent_id, :string
        add :most_surprising, :text
        add :most_time_consuming, :text
        add :improvements_needed, :text
        add :tools_wish_list, :text
        add :info_needed, :text
        timestamps(type: :utc_datetime)
      end

      # === From 20260514150002_add_guidance_fields_to_task_completion_feedback.exs ===
      alter table(:task_completion_feedback) do
        add :guidance_useful, :boolean
        add :guidance_items_helpful, :text
        add :guidance_items_confusing, :text
        add :guidance_missing, :text
      end

      # === From 20260516120001_add_telemetry_columns_to_acs_tool_operations.exs ===
      # These columns already included in acs_tool_operations table above
      # (execution_chain_id, sequence_order, attempt, tool_discovered, error_burst, params_hash)

      # === From 20260518120000_add_file_paths_to_acs_tasks.exs ===
      alter table(:acs_tasks) do
        add :file_paths, {:array, :string}, default: []
      end

      # === From 20260519120000_add_auditor_flags_to_acs_memories.exs ===
      alter table(:acs_memories) do
        add :auditor_flags, :text
      end
    end
  end
end
