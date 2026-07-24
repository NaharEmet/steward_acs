defmodule Acs.Accounts.OrganizationInvitation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "organization_invitations" do
    field :email, :string
    field :normalized_email, :string
    field :role, :string
    field :token_hash, :binary
    field :expires_at, :utc_datetime
    field :accepted_at, :utc_datetime
    field :revoked_at, :utc_datetime
    field :sent_at, :utc_datetime
    field :send_count, :integer, default: 0
    belongs_to :organization, Acs.Orgs.Organization
    belongs_to :inviter, Acs.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(invitation, attrs) do
    invitation
    |> cast(attrs, [
      :organization_id,
      :email,
      :normalized_email,
      :role,
      :inviter_id,
      :token_hash,
      :expires_at,
      :accepted_at,
      :revoked_at,
      :sent_at,
      :send_count
    ])
    |> normalize_email()
    |> validate_required([
      :organization_id,
      :email,
      :normalized_email,
      :role,
      :token_hash,
      :expires_at
    ])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must be a valid email")
    |> validate_length(:email, max: 160)
    |> validate_inclusion(:role, ~w(owner admin member))
    |> foreign_key_constraint(:organization_id)
    |> foreign_key_constraint(:inviter_id)
    |> unique_constraint(:token_hash, name: :organization_invitations_token_hash_index)
    |> unique_constraint(:normalized_email,
      name: :organization_invitations_pending_org_email_index
    )
  end

  defp normalize_email(changeset) do
    case get_change(changeset, :email) do
      email when is_binary(email) ->
        put_change(changeset, :normalized_email, email |> String.trim() |> String.downcase())

      _ ->
        changeset
    end
  end
end
