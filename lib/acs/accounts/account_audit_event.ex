defmodule Acs.Accounts.AccountAuditEvent do
  use Ecto.Schema
  import Ecto.Changeset

  schema "account_audit_events" do
    field :event, :string
    field :metadata, :string
    belongs_to :actor, Acs.Accounts.User
    belongs_to :organization, Acs.Orgs.Organization
    belongs_to :target_user, Acs.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:actor_id, :organization_id, :target_user_id, :event, :metadata])
    |> validate_required([:event])
    |> foreign_key_constraint(:actor_id)
    |> foreign_key_constraint(:organization_id)
    |> foreign_key_constraint(:target_user_id)
  end
end
