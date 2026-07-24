defmodule Acs.Repo.Migrations.CreateOrganizationMembershipSystem do
  use Ecto.Migration

  def up do
    create table(:organizations) do
      add(:name, :string, null: false)
      add(:slug, :string, null: false)
      add(:subdomain, :string, null: false)
      add(:plan, :string, null: false, default: "free")
      add(:provisioning_status, :string, null: false, default: "pending")
      add(:provisioning_error, :text)
      add(:provisioned_at, :utc_datetime)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:organizations, [:slug], name: :organizations_slug_index))
    create(unique_index(:organizations, [:subdomain], name: :organizations_subdomain_index))

    execute("""
    INSERT INTO organizations (name, slug, subdomain, plan, provisioning_status, inserted_at, updated_at)
    VALUES ('Default', 'default', 'default', 'free', 'ready', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    ON CONFLICT (slug) DO NOTHING
    """)

    execute("""
    INSERT INTO organizations (name, slug, subdomain, plan, provisioning_status, inserted_at, updated_at)
    SELECT DISTINCT TRIM(org), LOWER(TRIM(org)), LOWER(TRIM(org)), 'free', 'ready', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM users
    WHERE org IS NOT NULL AND TRIM(org) <> ''
    ON CONFLICT (slug) DO NOTHING
    """)

    alter table(:users) do
      add(:name, :string)
      add(:normalized_email, :string)
      add(:oidc_issuer, :string)
      add(:oidc_subject, :string)
      add(:organization_id, references(:organizations, on_delete: :nilify_all))
      add(:org_role, :string)
    end

    execute("UPDATE users SET normalized_email = LOWER(TRIM(email)) WHERE email IS NOT NULL")

    # Prod may already have duplicate emails across orgs (unique was email+org).
    # Prefer the earliest user id; drop orphan tokens for removed rows.
    execute("""
    DELETE FROM users_tokens
    WHERE user_id IN (
      SELECT u.id FROM users u
      WHERE u.normalized_email IS NOT NULL
        AND u.id NOT IN (
          SELECT MIN(u2.id) FROM users u2
          WHERE u2.normalized_email IS NOT NULL
          GROUP BY u2.normalized_email
        )
    )
    """)

    execute("""
    DELETE FROM users
    WHERE normalized_email IS NOT NULL
      AND id NOT IN (
        SELECT MIN(id) FROM users
        WHERE normalized_email IS NOT NULL
        GROUP BY normalized_email
      )
    """)

    execute("""
    UPDATE users
    SET organization_id = (
      SELECT organizations.id FROM organizations
      WHERE organizations.slug = LOWER(TRIM(users.org))
    )
    WHERE organization_id IS NULL AND org IS NOT NULL AND TRIM(org) <> ''
    """)

    execute("UPDATE users SET org_role = 'member' WHERE organization_id IS NOT NULL")

    create(unique_index(:users, [:normalized_email], name: :users_normalized_email_index))
    create(unique_index(:users, [:oidc_issuer, :oidc_subject], name: :users_oidc_identity_index))
    create(index(:users, [:organization_id], name: :users_organization_id_index))

    if postgres?() do
      create(
        constraint(:users, :users_org_role_pair,
          check: "(organization_id IS NULL) = (org_role IS NULL)"
        )
      )

      create(
        constraint(:users, :users_org_role_valid,
          check: "org_role IS NULL OR org_role IN ('owner', 'admin', 'member')"
        )
      )
    end

    create table(:organization_invitations) do
      add(:organization_id, references(:organizations, on_delete: :delete_all), null: false)
      add(:email, :string, null: false)
      add(:normalized_email, :string, null: false)
      add(:role, :string, null: false)
      add(:inviter_id, references(:users, on_delete: :nilify_all))
      add(:token_hash, :binary, null: false)
      add(:expires_at, :utc_datetime, null: false)
      add(:accepted_at, :utc_datetime)
      add(:revoked_at, :utc_datetime)
      add(:sent_at, :utc_datetime)
      add(:send_count, :integer, null: false, default: 0)

      timestamps(type: :utc_datetime)
    end

    create(
      unique_index(:organization_invitations, [:token_hash],
        name: :organization_invitations_token_hash_index
      )
    )

    create(
      unique_index(:organization_invitations, [:organization_id, :normalized_email],
        name: :organization_invitations_pending_org_email_index,
        where: "accepted_at IS NULL AND revoked_at IS NULL"
      )
    )

    create(
      index(:organization_invitations, [:organization_id],
        name: :organization_invitations_organization_id_index
      )
    )

    create(
      index(:organization_invitations, [:organization_id, :normalized_email],
        name: :organization_invitations_org_email_index
      )
    )

    if postgres?() do
      create(
        constraint(:organization_invitations, :organization_invitations_role_valid,
          check: "role IN ('owner', 'admin', 'member')"
        )
      )
    end

    create table(:session_handoffs) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:organization_id, references(:organizations, on_delete: :delete_all), null: false)
      add(:token_hash, :binary, null: false)
      add(:state_hash, :binary)
      add(:return_to, :string)
      add(:expires_at, :utc_datetime, null: false)
      add(:consumed_at, :utc_datetime)

      timestamps(type: :utc_datetime)
    end

    create(
      unique_index(:session_handoffs, [:token_hash], name: :session_handoffs_token_hash_index)
    )

    create(index(:session_handoffs, [:user_id], name: :session_handoffs_user_id_index))

    create(
      index(:session_handoffs, [:organization_id], name: :session_handoffs_organization_id_index)
    )

    create table(:account_audit_events) do
      add(:actor_id, references(:users, on_delete: :nilify_all))
      add(:organization_id, references(:organizations, on_delete: :nilify_all))
      add(:target_user_id, references(:users, on_delete: :nilify_all))
      add(:event, :string, null: false)
      add(:metadata, :text)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create(
      index(:account_audit_events, [:organization_id],
        name: :account_audit_events_organization_id_index
      )
    )

    create(index(:account_audit_events, [:actor_id], name: :account_audit_events_actor_id_index))
  end

  def down do
    drop(table(:account_audit_events))
    drop(table(:session_handoffs))
    drop(table(:organization_invitations))

    if postgres?() do
      drop(constraint(:users, :users_org_role_valid))
      drop(constraint(:users, :users_org_role_pair))
    end

    drop(index(:users, [:organization_id], name: :users_organization_id_index))
    drop(index(:users, [:oidc_issuer, :oidc_subject], name: :users_oidc_identity_index))
    drop(index(:users, [:normalized_email], name: :users_normalized_email_index))

    alter table(:users) do
      remove(:org_role)
      remove(:organization_id)
      remove(:oidc_subject)
      remove(:oidc_issuer)
      remove(:normalized_email)
      remove(:name)
    end

    drop(table(:organizations))
  end

  defp postgres?, do: to_string(repo().__adapter__()) == "Elixir.Ecto.Adapters.Postgres"
end
