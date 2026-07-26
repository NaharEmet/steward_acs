defmodule Acs.Repo.Migrations.AgentStatusCompositePk do
  use Ecto.Migration

  def up do
    if postgres?() do
      # SQLite path below recreates the table with BLOB; Postgres already has
      # uuid/bytea columns — only the primary key shape needs to change.
      execute("""
      DELETE FROM acs_agent_status a
      USING acs_agent_status b
      WHERE a.ctid < b.ctid
        AND a.agent_id = b.agent_id
        AND COALESCE(a.org, 'default') = COALESCE(b.org, 'default')
      """)

      execute("UPDATE acs_agent_status SET org = 'default' WHERE org IS NULL")
      execute("ALTER TABLE acs_agent_status ALTER COLUMN org SET DEFAULT 'default'")
      execute("ALTER TABLE acs_agent_status ALTER COLUMN org SET NOT NULL")
      execute("ALTER TABLE acs_agent_status DROP CONSTRAINT IF EXISTS acs_agent_status_pkey")
      execute("ALTER TABLE acs_agent_status ADD PRIMARY KEY (agent_id, org)")

      # 20260705000002 may already have created this index.
      create_if_not_exists index(:acs_agent_status, [:org], name: :acs_agent_status_org_index)
    else
      execute("""
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
      """)

      execute("""
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
      """)

      drop table(:acs_agent_status)
      execute("ALTER TABLE acs_agent_status_new RENAME TO acs_agent_status")
      create index(:acs_agent_status, [:org], name: :acs_agent_status_org_index)
    end
  end

  def down do
    if postgres?() do
      execute("ALTER TABLE acs_agent_status DROP CONSTRAINT IF EXISTS acs_agent_status_pkey")
      execute("ALTER TABLE acs_agent_status ADD PRIMARY KEY (agent_id)")
    else
      execute("""
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
      """)

      execute("""
      INSERT INTO acs_agent_status_old (
        agent_id, org, current_task_id, purpose, application, component, inserted_at, updated_at
      )
      SELECT
        agent_id, org, current_task_id, purpose, application, component, inserted_at, updated_at
      FROM acs_agent_status
      WHERE rowid IN (
        SELECT MIN(rowid) FROM acs_agent_status GROUP BY agent_id
      )
      """)

      drop table(:acs_agent_status)
      execute("ALTER TABLE acs_agent_status_old RENAME TO acs_agent_status")
    end
  end

  defp postgres?, do: repo().__adapter__() == Ecto.Adapters.Postgres
end
