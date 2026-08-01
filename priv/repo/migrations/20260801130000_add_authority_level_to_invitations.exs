defmodule Acs.Repo.Migrations.AddAuthorityLevelToInvitations do
  use Ecto.Migration

  def up do
    alter table(:organization_invitations) do
      add :authority_level_slug, :string, null: true
    end
  end

  def down do
    alter table(:organization_invitations) do
      remove :authority_level_slug
    end
  end
end
