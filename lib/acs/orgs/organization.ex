defmodule Acs.Orgs.Organization do
  use Ecto.Schema
  import Ecto.Changeset

  @slug_regex ~r/^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/
  @reserved ~w(www obsidian api account)

  schema "organizations" do
    field :name, :string
    field :slug, :string
    field :subdomain, :string
    field :plan, :string, default: "free"
    field :provisioning_status, :string, default: "pending"
    field :provisioning_error, :string
    field :provisioned_at, :utc_datetime

    has_many :users, Acs.Accounts.User
    timestamps(type: :utc_datetime)
  end

  def changeset(organization, attrs) do
    organization
    |> cast(attrs, [
      :name,
      :slug,
      :subdomain,
      :plan,
      :provisioning_status,
      :provisioning_error,
      :provisioned_at
    ])
    |> normalize_fields()
    |> validate_required([:name, :slug, :subdomain, :plan, :provisioning_status])
    |> validate_length(:name, max: 160)
    |> validate_format(:slug, @slug_regex,
      message: "must contain lowercase letters, numbers, or hyphens"
    )
    |> validate_format(:subdomain, @slug_regex,
      message: "must contain lowercase letters, numbers, or hyphens"
    )
    |> validate_exclusion(:slug, @reserved, message: "is reserved")
    |> validate_exclusion(:subdomain, @reserved, message: "is reserved")
    |> validate_inclusion(:provisioning_status, ~w(pending ready failed))
    |> immutable_identity(organization)
    |> unique_constraint(:slug, name: :organizations_slug_index)
    |> unique_constraint(:subdomain, name: :organizations_subdomain_index)
  end

  def provisioning_changeset(organization, attrs) do
    organization
    |> cast(attrs, [:provisioning_status, :provisioning_error, :provisioned_at])
    |> validate_required([:provisioning_status])
    |> validate_inclusion(:provisioning_status, ~w(pending ready failed))
  end

  defp normalize_fields(changeset) do
    changeset
    |> update_change(:name, &String.trim/1)
    |> update_change(:slug, &(String.trim(&1) |> String.downcase()))
    |> update_change(:subdomain, &(String.trim(&1) |> String.downcase()))
  end

  defp immutable_identity(changeset, %{id: nil}), do: changeset

  defp immutable_identity(changeset, _organization) do
    changeset
    |> validate_change(:slug, fn :slug, _ -> [slug: "is immutable"] end)
    |> validate_change(:subdomain, fn :subdomain, _ -> [subdomain: "is immutable"] end)
  end
end
