defmodule Acs.Repo.Migrations.AddTelemetryColumnsToAcsToolOperations do
  use Ecto.Migration

  def change do
    alter table(:acs_tool_operations) do
      add :execution_chain_id, :string
      add :sequence_order, :integer, default: 0
      add :attempt, :integer, default: 1
      add :tool_discovered, :boolean, default: false
      add :error_burst, :boolean, default: false
      add :params_hash, :string
    end

    create index(:acs_tool_operations, [:execution_chain_id])
    create index(:acs_tool_operations, [:tool_discovered])
  end
end