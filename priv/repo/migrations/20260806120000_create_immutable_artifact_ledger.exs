defmodule Acs.Repo.Migrations.CreateImmutableArtifactLedger do
  use Ecto.Migration

  def up do
    create table(:company_artifacts, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:organization_id, references(:organizations, on_delete: :restrict), null: false)
      add(:kind, :string, null: false)
      add(:public_id, :string, null: false)
      add(:head_revision_id, :string)
      add(:created_at, :utc_datetime, null: false)
    end

    create(unique_index(:company_artifacts, [:organization_id, :kind, :public_id]))
    create(index(:company_artifacts, [:organization_id]))

    create table(:artifact_commits, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:organization_id, references(:organizations, on_delete: :restrict), null: false)
      add(:sequence, :integer, null: false)
      add(:parent_commit_id, references(:artifact_commits, type: :string, on_delete: :restrict))
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

    create(unique_index(:artifact_commits, [:organization_id, :sequence]))
    create(unique_index(:artifact_commits, [:organization_id, :commit_hash]))

    create(
      unique_index(:artifact_commits, [:organization_id, :request_id],
        name: :artifact_commits_org_request_id_index
      )
    )

    create(index(:artifact_commits, [:organization_id, :committed_at]))

    create table(:artifact_revisions, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:organization_id, references(:organizations, on_delete: :restrict), null: false)

      add(:artifact_id, references(:company_artifacts, type: :string, on_delete: :restrict),
        null: false
      )

      add(:revision_number, :integer, null: false)

      add(:parent_revision_id, references(:artifact_revisions, type: :string, on_delete: :restrict))
      add(:parent_revision_hash, :string)
      add(:commit_id, references(:artifact_commits, type: :string, on_delete: :restrict), null: false)
      add(:operation, :string, null: false)
      add(:snapshot_json, :text, null: false)
      add(:metadata_json, :text)
      add(:content_hash, :string, null: false)
      add(:revision_hash, :string, null: false)
      add(:inserted_at, :utc_datetime, null: false)
    end

    create(
      unique_index(:artifact_revisions, [:organization_id, :artifact_id, :revision_number],
        name: :artifact_revisions_org_artifact_number_index
      )
    )

    create(
      index(:artifact_revisions, [:organization_id, :content_hash],
        name: :artifact_revisions_org_content_hash_index
      )
    )

    create(index(:artifact_revisions, [:organization_id, :artifact_id, :inserted_at]))
    create(unique_index(:artifact_revisions, [:commit_id]))

    create table(:acs_skills) do
      add(:organization_id, references(:organizations, on_delete: :restrict), null: false)

      add(:company_artifact_id, references(:company_artifacts, type: :string, on_delete: :restrict),
        null: false
      )

      add(:head_revision_id, references(:artifact_revisions, type: :string, on_delete: :restrict),
        null: false
      )

      add(:public_id, :string, null: false)
      add(:name, :string, null: false)
      add(:description, :text)
      add(:status, :string)
      add(:tags_json, :text)
      add(:scope_paths_json, :text)
      add(:content, :text)
      add(:snapshot_json, :text, null: false)
    end

    create(unique_index(:acs_skills, [:organization_id, :company_artifact_id]))
    create(unique_index(:acs_skills, [:organization_id, :public_id]))
    create(index(:acs_skills, [:organization_id, :name]))
    create(index(:acs_skills, [:organization_id, :status]))

    create table(:acs_specs) do
      add(:organization_id, references(:organizations, on_delete: :restrict), null: false)

      add(:company_artifact_id, references(:company_artifacts, type: :string, on_delete: :restrict),
        null: false
      )

      add(:head_revision_id, references(:artifact_revisions, type: :string, on_delete: :restrict),
        null: false
      )

      add(:public_id, :string, null: false)
      add(:app, :string, null: false)
      add(:spec_id, :string, null: false)
      add(:title, :string)
      add(:status, :string)
      add(:document_type, :string)
      add(:tags_json, :text)
      add(:content, :text)
      add(:snapshot_json, :text, null: false)
    end

    create(unique_index(:acs_specs, [:organization_id, :company_artifact_id]))
    create(unique_index(:acs_specs, [:organization_id, :public_id]))
    create(unique_index(:acs_specs, [:organization_id, :app, :spec_id]))
    create(index(:acs_specs, [:organization_id, :status]))

    create table(:acs_tenant_tools) do
      add(:organization_id, references(:organizations, on_delete: :restrict), null: false)

      add(:company_artifact_id, references(:company_artifacts, type: :string, on_delete: :restrict),
        null: false
      )

      add(:head_revision_id, references(:artifact_revisions, type: :string, on_delete: :restrict),
        null: false
      )

      add(:public_id, :string, null: false)
      add(:app, :string, null: false)
      add(:name, :string, null: false)
      add(:description, :text)
      add(:category, :string)
      add(:definition_json, :text, null: false)
      add(:snapshot_json, :text, null: false)
    end

    create(unique_index(:acs_tenant_tools, [:organization_id, :company_artifact_id]))
    create(unique_index(:acs_tenant_tools, [:organization_id, :public_id]))
    create(unique_index(:acs_tenant_tools, [:organization_id, :app, :name]))
    create(index(:acs_tenant_tools, [:organization_id, :category]))

    install_guards()
  end

  def down do
    remove_guards()
    drop(table(:acs_tenant_tools))
    drop(table(:acs_specs))
    drop(table(:acs_skills))
    drop(table(:artifact_revisions))
    drop(table(:artifact_commits))
    drop(table(:company_artifacts))
  end

  defp install_guards do
    if postgres?() do
      execute("""
      CREATE FUNCTION reject_artifact_ledger_mutation() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'artifact ledger rows are immutable';
      END;
      $$ LANGUAGE plpgsql;
      """)

      execute("""
      CREATE FUNCTION validate_artifact_commit_insert() RETURNS trigger AS $$
      BEGIN
        IF NEW.sequence < 1 OR length(NEW.commit_hash) <> 64 THEN
          RAISE EXCEPTION 'invalid artifact commit sequence or hash';
        END IF;
        IF NEW.actor_type NOT IN ('user', 'developer_key', 'system', 'importer', 'agent') OR
           NEW.source NOT IN ('mcp', 'web', 'auditor', 'migration', 'system', 'meta_harness') THEN
          RAISE EXCEPTION 'invalid artifact commit actor or source';
        END IF;
        IF (NEW.parent_commit_id IS NULL) <> (NEW.parent_commit_hash IS NULL) THEN
          RAISE EXCEPTION 'artifact commit parent id/hash must both be set or null';
        END IF;
        IF NEW.parent_commit_id IS NULL AND NEW.sequence <> 1 THEN
          RAISE EXCEPTION 'genesis artifact commit must have sequence 1';
        END IF;
        IF NEW.parent_commit_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM artifact_commits p
          WHERE p.id = NEW.parent_commit_id
            AND p.organization_id = NEW.organization_id
            AND p.sequence = NEW.sequence - 1
            AND p.commit_hash = NEW.parent_commit_hash
        ) THEN
          RAISE EXCEPTION 'invalid cross-tenant or non-contiguous artifact commit parent';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      """)

      execute("""
      CREATE FUNCTION validate_artifact_revision_insert() RETURNS trigger AS $$
      BEGIN
        IF NEW.revision_number < 1 OR length(NEW.content_hash) <> 64 OR length(NEW.revision_hash) <> 64 THEN
          RAISE EXCEPTION 'invalid artifact revision number or hash';
        END IF;
        IF NEW.operation NOT IN ('create', 'revise', 'transition', 'restore', 'tombstone', 'import') THEN
          RAISE EXCEPTION 'invalid artifact revision operation';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM company_artifacts a WHERE a.id = NEW.artifact_id AND a.organization_id = NEW.organization_id) OR
           NOT EXISTS (SELECT 1 FROM artifact_commits c WHERE c.id = NEW.commit_id AND c.organization_id = NEW.organization_id) THEN
          RAISE EXCEPTION 'cross-tenant artifact revision relationship';
        END IF;
        IF (NEW.parent_revision_id IS NULL) <> (NEW.parent_revision_hash IS NULL) THEN
          RAISE EXCEPTION 'artifact revision parent id/hash must both be set or null';
        END IF;
        IF NEW.parent_revision_id IS NULL AND NEW.revision_number <> 1 THEN
          RAISE EXCEPTION 'genesis artifact revision must have revision number 1';
        END IF;
        IF NEW.parent_revision_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM artifact_revisions p
          WHERE p.id = NEW.parent_revision_id
            AND p.organization_id = NEW.organization_id
            AND p.artifact_id = NEW.artifact_id
            AND p.revision_number = NEW.revision_number - 1
            AND p.revision_hash = NEW.parent_revision_hash
        ) THEN
          RAISE EXCEPTION 'invalid cross-tenant or non-contiguous artifact revision parent';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      """)

      execute("""
      CREATE FUNCTION validate_company_artifact_head() RETURNS trigger AS $$
      BEGIN
        IF NEW.kind NOT IN ('skill', 'spec', 'tool') THEN
          RAISE EXCEPTION 'invalid artifact kind';
        END IF;
        IF TG_OP = 'UPDATE' AND (
          NEW.id IS DISTINCT FROM OLD.id OR
          NEW.organization_id IS DISTINCT FROM OLD.organization_id OR
          NEW.kind IS DISTINCT FROM OLD.kind OR
          NEW.public_id IS DISTINCT FROM OLD.public_id OR
          NEW.created_at IS DISTINCT FROM OLD.created_at
        ) THEN
          RAISE EXCEPTION 'artifact identity fields are immutable';
        END IF;
        IF NEW.head_revision_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM artifact_revisions r
          WHERE r.id = NEW.head_revision_id
            AND r.organization_id = NEW.organization_id
            AND r.artifact_id = NEW.id
        ) THEN
          RAISE EXCEPTION 'invalid or cross-tenant company artifact head';
        END IF;
        IF TG_OP = 'UPDATE' AND OLD.head_revision_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM artifact_revisions r
          WHERE r.id = NEW.head_revision_id
            AND r.parent_revision_id = OLD.head_revision_id
        ) THEN
          RAISE EXCEPTION 'company artifact head must advance to a direct child revision';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      """)

      execute("""
      CREATE FUNCTION validate_artifact_projection() RETURNS trigger AS $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM company_artifacts a
          JOIN artifact_revisions r ON r.id = NEW.head_revision_id
          WHERE a.id = NEW.company_artifact_id
            AND a.organization_id = NEW.organization_id
            AND a.kind = TG_ARGV[0]
            AND a.head_revision_id = NEW.head_revision_id
            AND r.organization_id = NEW.organization_id
            AND r.artifact_id = a.id
            AND r.snapshot_json = NEW.snapshot_json
        ) THEN
          RAISE EXCEPTION 'invalid artifact projection head, kind, or snapshot';
        END IF;
        IF TG_OP = 'UPDATE' AND (
          NEW.company_artifact_id IS DISTINCT FROM OLD.company_artifact_id OR
          NEW.organization_id IS DISTINCT FROM OLD.organization_id OR
          NEW.head_revision_id IS NOT DISTINCT FROM OLD.head_revision_id OR
          NOT EXISTS (
            SELECT 1 FROM artifact_revisions r
            WHERE r.id = NEW.head_revision_id
              AND r.parent_revision_id = OLD.head_revision_id
          )
        ) THEN
          RAISE EXCEPTION 'artifact projection must advance to a direct child revision';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      """)

      execute("CREATE TRIGGER artifact_commits_validate BEFORE INSERT ON artifact_commits FOR EACH ROW EXECUTE FUNCTION validate_artifact_commit_insert()")
      execute("CREATE TRIGGER artifact_revisions_validate BEFORE INSERT ON artifact_revisions FOR EACH ROW EXECUTE FUNCTION validate_artifact_revision_insert()")
      execute("CREATE TRIGGER company_artifacts_validate_insert BEFORE INSERT ON company_artifacts FOR EACH ROW EXECUTE FUNCTION validate_company_artifact_head()")
      execute("CREATE TRIGGER company_artifacts_validate_head BEFORE UPDATE ON company_artifacts FOR EACH ROW EXECUTE FUNCTION validate_company_artifact_head()")
      execute("CREATE TRIGGER acs_skills_validate_artifact BEFORE INSERT OR UPDATE ON acs_skills FOR EACH ROW EXECUTE FUNCTION validate_artifact_projection('skill')")
      execute("CREATE TRIGGER acs_specs_validate_artifact BEFORE INSERT OR UPDATE ON acs_specs FOR EACH ROW EXECUTE FUNCTION validate_artifact_projection('spec')")
      execute("CREATE TRIGGER acs_tenant_tools_validate_artifact BEFORE INSERT OR UPDATE ON acs_tenant_tools FOR EACH ROW EXECUTE FUNCTION validate_artifact_projection('tool')")
      execute("CREATE TRIGGER artifact_commits_immutable BEFORE UPDATE OR DELETE ON artifact_commits FOR EACH ROW EXECUTE FUNCTION reject_artifact_ledger_mutation()")
      execute("CREATE TRIGGER artifact_revisions_immutable BEFORE UPDATE OR DELETE ON artifact_revisions FOR EACH ROW EXECUTE FUNCTION reject_artifact_ledger_mutation()")
      execute("CREATE TRIGGER artifact_commits_immutable_truncate BEFORE TRUNCATE ON artifact_commits FOR EACH STATEMENT EXECUTE FUNCTION reject_artifact_ledger_mutation()")
      execute("CREATE TRIGGER artifact_revisions_immutable_truncate BEFORE TRUNCATE ON artifact_revisions FOR EACH STATEMENT EXECUTE FUNCTION reject_artifact_ledger_mutation()")
    else
      execute("""
      CREATE TRIGGER artifact_commits_validate
      BEFORE INSERT ON artifact_commits BEGIN
        SELECT CASE WHEN NEW.sequence < 1 OR length(NEW.commit_hash) <> 64
          THEN RAISE(ABORT, 'invalid artifact commit sequence or hash') END;
        SELECT CASE WHEN NEW.actor_type NOT IN ('user', 'developer_key', 'system', 'importer', 'agent') OR NEW.source NOT IN ('mcp', 'web', 'auditor', 'migration', 'system', 'meta_harness')
          THEN RAISE(ABORT, 'invalid artifact commit actor or source') END;
        SELECT CASE WHEN (NEW.parent_commit_id IS NULL) <> (NEW.parent_commit_hash IS NULL)
          THEN RAISE(ABORT, 'artifact commit parent id/hash must both be set or null') END;
        SELECT CASE WHEN NEW.parent_commit_id IS NULL AND NEW.sequence <> 1
          THEN RAISE(ABORT, 'genesis artifact commit must have sequence 1') END;
        SELECT CASE WHEN NEW.parent_commit_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM artifact_commits p
          WHERE p.id = NEW.parent_commit_id AND p.organization_id = NEW.organization_id
            AND p.sequence = NEW.sequence - 1 AND p.commit_hash = NEW.parent_commit_hash
        ) THEN RAISE(ABORT, 'invalid artifact commit parent') END;
      END;
      """)

      execute("""
      CREATE TRIGGER artifact_revisions_validate
      BEFORE INSERT ON artifact_revisions BEGIN
        SELECT CASE WHEN NEW.revision_number < 1 OR length(NEW.content_hash) <> 64 OR length(NEW.revision_hash) <> 64
          THEN RAISE(ABORT, 'invalid artifact revision number or hash') END;
        SELECT CASE WHEN NEW.operation NOT IN ('create', 'revise', 'transition', 'restore', 'tombstone', 'import')
          THEN RAISE(ABORT, 'invalid artifact revision operation') END;
        SELECT CASE WHEN NOT EXISTS (
          SELECT 1 FROM company_artifacts a WHERE a.id = NEW.artifact_id AND a.organization_id = NEW.organization_id
        ) OR NOT EXISTS (
          SELECT 1 FROM artifact_commits c WHERE c.id = NEW.commit_id AND c.organization_id = NEW.organization_id
        ) THEN RAISE(ABORT, 'cross-tenant artifact revision relationship') END;
        SELECT CASE WHEN (NEW.parent_revision_id IS NULL) <> (NEW.parent_revision_hash IS NULL)
          THEN RAISE(ABORT, 'artifact revision parent id/hash must both be set or null') END;
        SELECT CASE WHEN NEW.parent_revision_id IS NULL AND NEW.revision_number <> 1
          THEN RAISE(ABORT, 'genesis artifact revision must have revision number 1') END;
        SELECT CASE WHEN NEW.parent_revision_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM artifact_revisions p
          WHERE p.id = NEW.parent_revision_id AND p.organization_id = NEW.organization_id
            AND p.artifact_id = NEW.artifact_id AND p.revision_number = NEW.revision_number - 1
            AND p.revision_hash = NEW.parent_revision_hash
        ) THEN RAISE(ABORT, 'invalid artifact revision parent') END;
      END;
      """)

      execute("""
      CREATE TRIGGER company_artifacts_validate_insert
      BEFORE INSERT ON company_artifacts BEGIN
        SELECT CASE WHEN NEW.kind NOT IN ('skill', 'spec', 'tool')
          THEN RAISE(ABORT, 'invalid artifact kind') END;
        SELECT CASE WHEN NEW.head_revision_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM artifact_revisions r
          WHERE r.id = NEW.head_revision_id AND r.organization_id = NEW.organization_id AND r.artifact_id = NEW.id
        ) THEN RAISE(ABORT, 'invalid company artifact head') END;
      END;
      """)

      execute("""
      CREATE TRIGGER company_artifacts_validate_head
      BEFORE UPDATE ON company_artifacts BEGIN
        SELECT CASE WHEN NEW.id <> OLD.id OR NEW.organization_id <> OLD.organization_id OR
          NEW.kind <> OLD.kind OR NEW.public_id <> OLD.public_id OR NEW.created_at <> OLD.created_at
          THEN RAISE(ABORT, 'artifact identity fields are immutable') END;
        SELECT CASE WHEN NEW.head_revision_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM artifact_revisions r
          WHERE r.id = NEW.head_revision_id AND r.organization_id = NEW.organization_id AND r.artifact_id = NEW.id
        ) THEN RAISE(ABORT, 'invalid company artifact head') END;
        SELECT CASE WHEN OLD.head_revision_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM artifact_revisions r
          WHERE r.id = NEW.head_revision_id AND r.parent_revision_id = OLD.head_revision_id
        ) THEN RAISE(ABORT, 'company artifact head must advance to a direct child revision') END;
      END;
      """)

      install_sqlite_projection_guard("acs_skills", "skill")
      install_sqlite_projection_guard("acs_specs", "spec")
      install_sqlite_projection_guard("acs_tenant_tools", "tool")

      execute("""
      CREATE TRIGGER artifact_commits_immutable_update
      BEFORE UPDATE ON artifact_commits BEGIN
        SELECT RAISE(ABORT, 'artifact ledger rows are immutable');
      END;
      """)

      execute("""
      CREATE TRIGGER artifact_commits_immutable_delete
      BEFORE DELETE ON artifact_commits BEGIN
        SELECT RAISE(ABORT, 'artifact ledger rows are immutable');
      END;
      """)

      execute("""
      CREATE TRIGGER artifact_revisions_immutable_update
      BEFORE UPDATE ON artifact_revisions BEGIN
        SELECT RAISE(ABORT, 'artifact ledger rows are immutable');
      END;
      """)

      execute("""
      CREATE TRIGGER artifact_revisions_immutable_delete
      BEFORE DELETE ON artifact_revisions BEGIN
        SELECT RAISE(ABORT, 'artifact ledger rows are immutable');
      END;
      """)
    end
  end

  defp install_sqlite_projection_guard(table, kind) do
    for event <- ["INSERT", "UPDATE"] do
      transition_guard =
        if event == "UPDATE" do
          """
          SELECT CASE WHEN NEW.company_artifact_id <> OLD.company_artifact_id OR
            NEW.organization_id <> OLD.organization_id OR NEW.head_revision_id = OLD.head_revision_id OR
            NOT EXISTS (SELECT 1 FROM artifact_revisions r
              WHERE r.id = NEW.head_revision_id AND r.parent_revision_id = OLD.head_revision_id)
            THEN RAISE(ABORT, 'artifact projection must advance to a direct child revision') END;
          """
        else
          ""
        end

      execute("""
      CREATE TRIGGER #{table}_validate_artifact_#{String.downcase(event)}
      BEFORE #{event} ON #{table} BEGIN
        SELECT CASE WHEN NOT EXISTS (
          SELECT 1 FROM company_artifacts a
          JOIN artifact_revisions r ON r.id = NEW.head_revision_id
          WHERE a.id = NEW.company_artifact_id
            AND a.organization_id = NEW.organization_id
            AND a.kind = '#{kind}'
            AND a.head_revision_id = NEW.head_revision_id
            AND r.organization_id = NEW.organization_id
            AND r.artifact_id = a.id
            AND r.snapshot_json = NEW.snapshot_json
        ) THEN RAISE(ABORT, 'invalid artifact projection head, kind, or snapshot') END;
        #{transition_guard}
      END;
      """)
    end
  end

  defp remove_guards do
    if postgres?() do
      for {table, trigger} <- [
            {"artifact_revisions", "artifact_revisions_immutable_truncate"},
            {"artifact_commits", "artifact_commits_immutable_truncate"},
            {"artifact_revisions", "artifact_revisions_immutable"},
            {"artifact_commits", "artifact_commits_immutable"},
            {"acs_tenant_tools", "acs_tenant_tools_validate_artifact"},
            {"acs_specs", "acs_specs_validate_artifact"},
            {"acs_skills", "acs_skills_validate_artifact"},
            {"company_artifacts", "company_artifacts_validate_head"},
            {"company_artifacts", "company_artifacts_validate_insert"},
            {"artifact_revisions", "artifact_revisions_validate"},
            {"artifact_commits", "artifact_commits_validate"}
          ] do
        execute("DROP TRIGGER IF EXISTS #{trigger} ON #{table}")
      end

      execute("DROP FUNCTION IF EXISTS validate_artifact_projection()")
      execute("DROP FUNCTION IF EXISTS validate_company_artifact_head()")
      execute("DROP FUNCTION IF EXISTS validate_artifact_revision_insert()")
      execute("DROP FUNCTION IF EXISTS validate_artifact_commit_insert()")
      execute("DROP FUNCTION IF EXISTS reject_artifact_ledger_mutation()")
    else
      for trigger <- [
            "artifact_revisions_immutable_delete",
            "artifact_revisions_immutable_update",
            "artifact_commits_immutable_delete",
            "artifact_commits_immutable_update",
            "acs_tenant_tools_validate_artifact_update",
            "acs_tenant_tools_validate_artifact_insert",
            "acs_specs_validate_artifact_update",
            "acs_specs_validate_artifact_insert",
            "acs_skills_validate_artifact_update",
            "acs_skills_validate_artifact_insert",
            "company_artifacts_validate_head",
            "company_artifacts_validate_insert",
            "artifact_revisions_validate",
            "artifact_commits_validate"
          ] do
        execute("DROP TRIGGER IF EXISTS #{trigger}")
      end
    end
  end

  defp postgres?, do: to_string(repo().__adapter__()) == "Elixir.Ecto.Adapters.Postgres"
end
