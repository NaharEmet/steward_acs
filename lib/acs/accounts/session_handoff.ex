defmodule Acs.Accounts.SessionHandoff do
  use Ecto.Schema
  import Ecto.Changeset

  schema "session_handoffs" do
    field :token_hash, :binary
    field :state_hash, :binary
    field :return_to, :string
    field :expires_at, :utc_datetime
    field :consumed_at, :utc_datetime
    belongs_to :user, Acs.Accounts.User
    belongs_to :organization, Acs.Orgs.Organization

    timestamps(type: :utc_datetime)
  end

  def changeset(handoff, attrs) do
    handoff
    |> cast(attrs, [
      :user_id,
      :organization_id,
      :token_hash,
      :state_hash,
      :return_to,
      :expires_at,
      :consumed_at
    ])
    |> validate_required([:user_id, :organization_id, :token_hash, :expires_at])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:organization_id)
    |> unique_constraint(:token_hash, name: :session_handoffs_token_hash_index)
  end
end
