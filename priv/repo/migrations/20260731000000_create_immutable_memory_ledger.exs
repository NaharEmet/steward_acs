defmodule Acs.Repo.Migrations.CreateImmutableMemoryLedger do
  use Ecto.Migration

  def up do
    create table(:company_memories, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:organization_id, references(:organizations, on_delete: :restrict), null: false)
      add(:public_id, :string, null: false)
      add(:head_revision_id, :string)
      add(:created_at, :utc_datetime, null: false)
    end

    create(unique_index(:company_memories, [:organization_id, :public_id]))
    create(index(:company_memories, [:organization_id]))

    create table(:memory_commits, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:organization_id, references(:organizations, on_delete: :restrict), null: false)
      add(:sequence, :integer, null: false)
      add(:parent_commit_id, references(:memory_commits, type: :string, on_delete: :restrict))
      add(:parent_commit_hash, :string)
      add(:actor_type, :string, null: false)
      add(:actor_id, :string, null: false)
      add(:actor_display, :string)
      add(:message, :text, null: false)
      add(:source, :string, null: false)
      add(:request_id, :string)
      add(:commit_hash, :string, null: false)
      add(:committed_at, :utc_datetime, null: false)
    end

    create(unique_index(:memory_commits, [:organization_id, :sequence]))
    create(unique_index(:memory_commits, [:organization_id, :commit_hash]))

    create(
      unique_index(:memory_commits, [:organization_id, :request_id],
        name: :memory_commits_org_request_id_index
      )
    )

    create(index(:memory_commits, [:organization_id, :committed_at]))

    create table(:memory_revisions, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:organization_id, references(:organizations, on_delete: :restrict), null: false)

      add(:memory_id, references(:company_memories, type: :string, on_delete: :restrict),
        null: false
      )

      add(:revision_number, :integer, null: false)
      add(:parent_revision_id, references(:memory_revisions, type: :string, on_delete: :restrict))
      add(:parent_revision_hash, :string)

      add(:commit_id, references(:memory_commits, type: :string, on_delete: :restrict),
        null: false
      )

      add(:operation, :string, null: false)
      add(:snapshot_json, :text, null: false)
      add(:metadata_json, :text)
      add(:content_hash, :string, null: false)
      add(:revision_hash, :string, null: false)
      add(:inserted_at, :utc_datetime, null: false)
    end

    create(
      unique_index(:memory_revisions, [:organization_id, :memory_id, :revision_number],
        name: :memory_revisions_org_memory_number_index
      )
    )

    create(
      index(:memory_revisions, [:organization_id, :content_hash],
        name: :memory_revisions_org_content_hash_index
      )
    )

    create(index(:memory_revisions, [:organization_id, :memory_id, :inserted_at]))
    create(unique_index(:memory_revisions, [:commit_id]))

    alter table(:acs_memories) do
      add(:company_memory_id, :string)
      add(:head_revision_id, :string)
    end

    create(index(:acs_memories, [:company_memory_id]))
    create(index(:acs_memories, [:head_revision_id]))

    install_immutability_guards()
  end

  def down do
    remove_immutability_guards()

    drop_if_exists(index(:acs_memories, [:head_revision_id]))
    drop_if_exists(index(:acs_memories, [:company_memory_id]))

    alter table(:acs_memories) do
      remove(:head_revision_id)
      remove(:company_memory_id)
    end

    drop(table(:memory_revisions))
    drop(table(:memory_commits))
    drop(table(:company_memories))
  end

  defp install_immutability_guards do
    if postgres?() do
      execute("""
      CREATE FUNCTION reject_memory_ledger_mutation() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'memory ledger rows are immutable';
      END;
      $$ LANGUAGE plpgsql;
      """)

      execute("""
      CREATE FUNCTION validate_memory_commit_insert() RETURNS trigger AS $$
      BEGIN
        IF NEW.sequence < 1 OR length(NEW.commit_hash) <> 64 THEN
          RAISE EXCEPTION 'invalid memory commit sequence or hash';
        END IF;
        IF (NEW.parent_commit_id IS NULL) <> (NEW.parent_commit_hash IS NULL) THEN
          RAISE EXCEPTION 'memory commit parent id/hash must both be set or null';
        END IF;
        IF NEW.parent_commit_id IS NULL AND NEW.sequence <> 1 THEN
          RAISE EXCEPTION 'genesis memory commit must have sequence 1';
        END IF;
        IF NEW.parent_commit_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM memory_commits p
          WHERE p.id = NEW.parent_commit_id
            AND p.organization_id = NEW.organization_id
            AND p.sequence = NEW.sequence - 1
            AND p.commit_hash = NEW.parent_commit_hash
        ) THEN
          RAISE EXCEPTION 'invalid cross-tenant or non-contiguous memory commit parent';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      """)

      execute("""
      CREATE FUNCTION validate_memory_revision_insert() RETURNS trigger AS $$
      BEGIN
        IF NEW.revision_number < 1 OR length(NEW.content_hash) <> 64 OR length(NEW.revision_hash) <> 64 THEN
          RAISE EXCEPTION 'invalid memory revision number or hash';
        END IF;
        IF NEW.operation NOT IN ('create', 'revise', 'transition', 'restore', 'tombstone', 'import') THEN
          RAISE EXCEPTION 'invalid memory revision operation';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM company_memories m WHERE m.id = NEW.memory_id AND m.organization_id = NEW.organization_id) OR
           NOT EXISTS (SELECT 1 FROM memory_commits c WHERE c.id = NEW.commit_id AND c.organization_id = NEW.organization_id) THEN
          RAISE EXCEPTION 'cross-tenant memory revision relationship';
        END IF;
        IF (NEW.parent_revision_id IS NULL) <> (NEW.parent_revision_hash IS NULL) THEN
          RAISE EXCEPTION 'memory revision parent id/hash must both be set or null';
        END IF;
        IF NEW.parent_revision_id IS NULL AND NEW.revision_number <> 1 THEN
          RAISE EXCEPTION 'genesis memory revision must have revision number 1';
        END IF;
        IF NEW.parent_revision_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM memory_revisions p
          WHERE p.id = NEW.parent_revision_id
            AND p.organization_id = NEW.organization_id
            AND p.memory_id = NEW.memory_id
            AND p.revision_number = NEW.revision_number - 1
            AND p.revision_hash = NEW.parent_revision_hash
        ) THEN
          RAISE EXCEPTION 'invalid cross-tenant or non-contiguous memory revision parent';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      """)

      execute("""
      CREATE FUNCTION validate_company_memory_head() RETURNS trigger AS $$
      BEGIN
        IF NEW.head_revision_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM memory_revisions r
          WHERE r.id = NEW.head_revision_id
            AND r.organization_id = NEW.organization_id
            AND r.memory_id = NEW.id
        ) THEN
          RAISE EXCEPTION 'invalid cross-tenant company memory head';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      """)

      execute(
        "CREATE TRIGGER memory_commits_validate BEFORE INSERT ON memory_commits FOR EACH ROW EXECUTE FUNCTION validate_memory_commit_insert()"
      )

      execute(
        "CREATE TRIGGER memory_revisions_validate BEFORE INSERT ON memory_revisions FOR EACH ROW EXECUTE FUNCTION validate_memory_revision_insert()"
      )

      execute(
        "CREATE TRIGGER company_memories_validate_head BEFORE UPDATE OF head_revision_id ON company_memories FOR EACH ROW EXECUTE FUNCTION validate_company_memory_head()"
      )

      execute("""
      CREATE TRIGGER memory_commits_immutable
      BEFORE UPDATE OR DELETE ON memory_commits
      FOR EACH ROW EXECUTE FUNCTION reject_memory_ledger_mutation();
      """)

      execute("""
      CREATE TRIGGER memory_revisions_immutable
      BEFORE UPDATE OR DELETE ON memory_revisions
      FOR EACH ROW EXECUTE FUNCTION reject_memory_ledger_mutation();
      """)

      execute("""
      CREATE TRIGGER memory_commits_immutable_truncate
      BEFORE TRUNCATE ON memory_commits
      FOR EACH STATEMENT EXECUTE FUNCTION reject_memory_ledger_mutation();
      """)

      execute("""
      CREATE TRIGGER memory_revisions_immutable_truncate
      BEFORE TRUNCATE ON memory_revisions
      FOR EACH STATEMENT EXECUTE FUNCTION reject_memory_ledger_mutation();
      """)
    else
      execute("""
      CREATE TRIGGER memory_commits_validate
      BEFORE INSERT ON memory_commits BEGIN
        SELECT CASE WHEN NEW.sequence < 1 OR length(NEW.commit_hash) <> 64
          THEN RAISE(ABORT, 'invalid memory commit sequence or hash') END;
        SELECT CASE WHEN (NEW.parent_commit_id IS NULL) <> (NEW.parent_commit_hash IS NULL)
          THEN RAISE(ABORT, 'memory commit parent id/hash must both be set or null') END;
        SELECT CASE WHEN NEW.parent_commit_id IS NULL AND NEW.sequence <> 1
          THEN RAISE(ABORT, 'genesis memory commit must have sequence 1') END;
        SELECT CASE WHEN NEW.parent_commit_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM memory_commits p
          WHERE p.id = NEW.parent_commit_id AND p.organization_id = NEW.organization_id
            AND p.sequence = NEW.sequence - 1 AND p.commit_hash = NEW.parent_commit_hash
        ) THEN RAISE(ABORT, 'invalid memory commit parent') END;
      END;
      """)

      execute("""
      CREATE TRIGGER memory_revisions_validate
      BEFORE INSERT ON memory_revisions BEGIN
        SELECT CASE WHEN NEW.revision_number < 1 OR length(NEW.content_hash) <> 64 OR length(NEW.revision_hash) <> 64
          THEN RAISE(ABORT, 'invalid memory revision number or hash') END;
        SELECT CASE WHEN NEW.operation NOT IN ('create', 'revise', 'transition', 'restore', 'tombstone', 'import')
          THEN RAISE(ABORT, 'invalid memory revision operation') END;
        SELECT CASE WHEN NOT EXISTS (
          SELECT 1 FROM company_memories m WHERE m.id = NEW.memory_id AND m.organization_id = NEW.organization_id
        ) OR NOT EXISTS (
          SELECT 1 FROM memory_commits c WHERE c.id = NEW.commit_id AND c.organization_id = NEW.organization_id
        ) THEN RAISE(ABORT, 'cross-tenant memory revision relationship') END;
        SELECT CASE WHEN (NEW.parent_revision_id IS NULL) <> (NEW.parent_revision_hash IS NULL)
          THEN RAISE(ABORT, 'memory revision parent id/hash must both be set or null') END;
        SELECT CASE WHEN NEW.parent_revision_id IS NULL AND NEW.revision_number <> 1
          THEN RAISE(ABORT, 'genesis memory revision must have revision number 1') END;
        SELECT CASE WHEN NEW.parent_revision_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM memory_revisions p
          WHERE p.id = NEW.parent_revision_id AND p.organization_id = NEW.organization_id
            AND p.memory_id = NEW.memory_id AND p.revision_number = NEW.revision_number - 1
            AND p.revision_hash = NEW.parent_revision_hash
        ) THEN RAISE(ABORT, 'invalid memory revision parent') END;
      END;
      """)

      execute("""
      CREATE TRIGGER company_memories_validate_head
      BEFORE UPDATE OF head_revision_id ON company_memories BEGIN
        SELECT CASE WHEN NEW.head_revision_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM memory_revisions r
          WHERE r.id = NEW.head_revision_id AND r.organization_id = NEW.organization_id AND r.memory_id = NEW.id
        ) THEN RAISE(ABORT, 'invalid company memory head') END;
      END;
      """)

      execute("""
      CREATE TRIGGER memory_commits_immutable_update
      BEFORE UPDATE ON memory_commits BEGIN
        SELECT RAISE(ABORT, 'memory ledger rows are immutable');
      END;
      """)

      execute("""
      CREATE TRIGGER memory_commits_immutable_delete
      BEFORE DELETE ON memory_commits BEGIN
        SELECT RAISE(ABORT, 'memory ledger rows are immutable');
      END;
      """)

      execute("""
      CREATE TRIGGER memory_revisions_immutable_update
      BEFORE UPDATE ON memory_revisions BEGIN
        SELECT RAISE(ABORT, 'memory ledger rows are immutable');
      END;
      """)

      execute("""
      CREATE TRIGGER memory_revisions_immutable_delete
      BEFORE DELETE ON memory_revisions BEGIN
        SELECT RAISE(ABORT, 'memory ledger rows are immutable');
      END;
      """)
    end
  end

  defp remove_immutability_guards do
    if postgres?() do
      execute("DROP TRIGGER IF EXISTS memory_revisions_immutable_truncate ON memory_revisions")
      execute("DROP TRIGGER IF EXISTS memory_commits_immutable_truncate ON memory_commits")
      execute("DROP TRIGGER IF EXISTS memory_revisions_immutable ON memory_revisions")
      execute("DROP TRIGGER IF EXISTS memory_commits_immutable ON memory_commits")
      execute("DROP TRIGGER IF EXISTS company_memories_validate_head ON company_memories")
      execute("DROP TRIGGER IF EXISTS memory_revisions_validate ON memory_revisions")
      execute("DROP TRIGGER IF EXISTS memory_commits_validate ON memory_commits")
      execute("DROP FUNCTION IF EXISTS validate_company_memory_head()")
      execute("DROP FUNCTION IF EXISTS validate_memory_revision_insert()")
      execute("DROP FUNCTION IF EXISTS validate_memory_commit_insert()")
      execute("DROP FUNCTION IF EXISTS reject_memory_ledger_mutation()")
    else
      execute("DROP TRIGGER IF EXISTS memory_revisions_immutable_delete")
      execute("DROP TRIGGER IF EXISTS memory_revisions_immutable_update")
      execute("DROP TRIGGER IF EXISTS memory_commits_immutable_delete")
      execute("DROP TRIGGER IF EXISTS memory_commits_immutable_update")
      execute("DROP TRIGGER IF EXISTS company_memories_validate_head")
      execute("DROP TRIGGER IF EXISTS memory_revisions_validate")
      execute("DROP TRIGGER IF EXISTS memory_commits_validate")
    end
  end

  defp postgres?, do: to_string(repo().__adapter__()) == "Elixir.Ecto.Adapters.Postgres"
end
