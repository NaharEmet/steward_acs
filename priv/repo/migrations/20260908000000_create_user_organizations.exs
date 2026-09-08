defmodule Acs.Repo.Migrations.CreateUserOrganizations do
  use Ecto.Migration

  def up do
    create table(:user_organizations) do
      add :user_id, :integer, null: false
      add :organization_id, :integer, null: false
      add :org_role, :string
      add :authority_level_slug, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:user_organizations, [:user_id, :organization_id],
             name: :user_organizations_user_org_index
           )

    create index(:user_organizations, [:user_id], name: :user_organizations_user_id_index)

    create index(:user_organizations, [:organization_id],
             name: :user_organizations_organization_id_index
           )
  end

  def down do
    drop index(:user_organizations, :user_organizations_organization_id_index)
    drop index(:user_organizations, :user_organizations_user_id_index)
    drop index(:user_organizations, :user_organizations_user_org_index)
    drop table(:user_organizations)
  end
end
