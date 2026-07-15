defmodule Acs.Repo.Migrations.AgentStatusCompositePk do
  use Ecto.Migration

  def up do
    execute """
    CREATE TABLE acs_agent_status_new (
      agent_id TEXT NOT NULL,
      org TEXT NOT NULL DEFAULT 'default',
      current_task_id BLOB,
      purpose TEXT,
      application TEXT,
      component TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      PRIMARY KEY (agent_id, org)
    )
    """

    execute """
    INSERT INTO acs_agent_status_new (
      agent_id, org, current_task_id, purpose, application, component, inserted_at, updated_at
    )
    SELECT
      agent_id,
      COALESCE(org, 'default'),
      current_task_id,
      purpose,
      application,
      component,
      inserted_at,
      updated_at
    FROM acs_agent_status
    """

    drop table(:acs_agent_status)
    execute "ALTER TABLE acs_agent_status_new RENAME TO acs_agent_status"
    create index(:acs_agent_status, [:org], name: :acs_agent_status_org_index)
  end

  def down do
    execute """
    CREATE TABLE acs_agent_status_old (
      agent_id TEXT NOT NULL PRIMARY KEY,
      org TEXT DEFAULT 'default',
      current_task_id BLOB,
      purpose TEXT,
      application TEXT,
      component TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """

    execute """
    INSERT INTO acs_agent_status_old (
      agent_id, org, current_task_id, purpose, application, component, inserted_at, updated_at
    )
    SELECT
      agent_id, org, current_task_id, purpose, application, component, inserted_at, updated_at
    FROM acs_agent_status
    WHERE rowid IN (
      SELECT MIN(rowid) FROM acs_agent_status GROUP BY agent_id
    )
    """

    drop table(:acs_agent_status)
    execute "ALTER TABLE acs_agent_status_old RENAME TO acs_agent_status"
  end
end
