defmodule Acs.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :confirmed_at, :utc_datetime
    field :org, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :org])
    |> validate_required([:email, :org])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must be a valid email")
    |> validate_length(:email, max: 160)
    |> validate_format(:org, ~r/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/,
      message: "must be a non-empty lowercase org slug"
    )
    |> unsafe_validate_unique([:email, :org], Acs.Repo)
    |> unique_constraint([:email, :org], name: :users_email_org_index)
  end

  @doc false
  def confirm_changeset(user) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    change(user, confirmed_at: now)
  end
end
