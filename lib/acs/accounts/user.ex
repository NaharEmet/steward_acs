defmodule Acs.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :normalized_email, :string
    field :name, :string
    field :confirmed_at, :utc_datetime
    field :oidc_issuer, :string
    field :oidc_subject, :string
    field :org, :string, default: "default"
    field :org_role, :string
    belongs_to :organization, Acs.Orgs.Organization

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(user, attrs) do
    user
    |> cast(attrs, [
      :email,
      :name,
      :confirmed_at,
      :oidc_issuer,
      :oidc_subject,
      :org,
      :organization_id,
      :org_role
    ])
    |> normalize_fields()
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must be a valid email")
    |> validate_length(:email, max: 160)
    |> validate_length(:name, max: 160)
    |> validate_org_membership()
    |> validate_inclusion(:org_role, ~w(owner admin member), allow_nil: true)
    |> foreign_key_constraint(:organization_id)
    |> unique_constraint(:normalized_email, name: :users_normalized_email_index)
    |> unique_constraint([:oidc_issuer, :oidc_subject], name: :users_oidc_identity_index)
    |> check_constraint(:org_role, name: :users_org_role_pair)
    |> check_constraint(:org_role, name: :users_org_role_valid)
  end

  @doc false
  def confirm_changeset(user) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    change(user, confirmed_at: now)
  end

  defp normalize_fields(changeset) do
    changeset
    |> update_change(:email, &trim/1)
    |> update_change(:name, &trim/1)
    |> update_change(:org, &normalize_org/1)
    |> update_change(:oidc_issuer, &trim/1)
    |> update_change(:oidc_subject, &trim/1)
    |> put_normalized_email()
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  defp normalize_org(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_org(value), do: value

  defp put_normalized_email(changeset) do
    case get_field(changeset, :email) do
      email when is_binary(email) ->
        put_change(changeset, :normalized_email, String.downcase(email))

      _ ->
        changeset
    end
  end

  defp validate_org_membership(changeset) do
    organization_id = get_field(changeset, :organization_id)
    org_role = get_field(changeset, :org_role)

    if is_nil(organization_id) == is_nil(org_role) do
      changeset
    else
      add_error(changeset, :organization_id, "and org role must both be set or both be empty")
    end
  end
end
