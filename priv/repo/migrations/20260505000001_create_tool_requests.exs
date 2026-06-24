defmodule Acs.Repo.Migrations.CreateToolRequests do
  use Ecto.Migration

  def change do
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

    create index(:tool_requests, [:status], name: :tool_requests_status_index)
    create index(:tool_requests, [:agent_id], name: :tool_requests_agent_id_index)
  end
end
