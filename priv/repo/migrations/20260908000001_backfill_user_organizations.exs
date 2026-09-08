defmodule Acs.Repo.Migrations.BackfillUserOrganizations do
  use Ecto.Migration

  def up do
    execute """
    INSERT INTO user_organizations (user_id, organization_id, org_role, authority_level_slug, inserted_at, updated_at)
    SELECT id, organization_id, org_role, authority_level_slug, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM users
    WHERE organization_id IS NOT NULL
    ON CONFLICT (user_id, organization_id) DO NOTHING
    """
  end

  def down do
    execute "DELETE FROM user_organizations WHERE true"
  end
end
