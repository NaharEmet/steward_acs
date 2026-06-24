defmodule Acs.Repo.Migrations.CreateAcsToolOperations do
  use Ecto.Migration

  def change do
    create table(:acs_tool_operations, primary_key: false) do
      add :id, :integer, primary_key: true, autogenerate: true
      add :agent_id, :string, null: true
      add :tool_name, :string, null: false
      add :execution_id, :string, null: true
      add :status, :string, null: false, default: "success"
      add :error_type, :string, null: true
      add :error_message, :text, null: true
      add :latency_ms, :integer, null: true
      add :created_at, :utc_datetime, null: false, default: fragment("CURRENT_TIMESTAMP")
    end

    create index(:acs_tool_operations, [:tool_name], name: :tool_ops_tool_name_idx)
    create index(:acs_tool_operations, [:status], name: :tool_ops_status_idx)
    create index(:acs_tool_operations, [:created_at], name: :tool_ops_created_at_idx)
    create index(:acs_tool_operations, [:agent_id], name: :tool_ops_agent_id_idx)
  end
end
