defmodule Acs.Accounts.UserOrganization do
  use Ecto.Schema
  import Ecto.Changeset

  schema "user_organizations" do
    belongs_to :user, Acs.Accounts.User
    belongs_to :organization, Acs.Orgs.Organization

    field :org_role, :string
    field :authority_level_slug, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(user_organization, attrs) do
    user_organization
    |> cast(attrs, [:user_id, :organization_id, :org_role, :authority_level_slug])
    |> validate_required([:user_id, :organization_id])
    |> validate_inclusion(:org_role, ~w(owner admin member), allow_nil: true)
    |> unique_constraint(:user_id_organization_id, name: :user_organizations_user_org_index)
  end
end
