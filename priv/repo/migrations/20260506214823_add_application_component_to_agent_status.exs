defmodule Acs.Repo.Migrations.AddApplicationComponentToAgentStatus do
  use Ecto.Migration

  def change do
    alter table(:acs_agent_status, primary_key: false) do
      add :application, :string
      add :component, :string
    end
  end
end
