defmodule Acs.AuthorityLevel do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @slug_regex ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/

  schema "acs_authority_levels" do
    field :org, :string
    field :slug, :string
    field :label, :string
    field :sort_order, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(level, attrs) do
    level
    |> cast(attrs, [:org, :slug, :label, :sort_order])
    |> update_change(:org, &trim_downcase/1)
    |> update_change(:slug, &normalize_slug/1)
    |> update_change(:label, &trim/1)
    |> validate_required([:org, :slug, :label, :sort_order])
    |> validate_length(:label, min: 1, max: 80)
    |> validate_length(:slug, min: 1, max: 64)
    |> validate_format(:slug, @slug_regex, message: "must be lowercase letters, numbers, hyphens")
    |> validate_number(:sort_order, greater_than: 0, less_than_or_equal_to: 100)
    |> unique_constraint([:org, :slug], name: :acs_authority_levels_org_slug_index)
    |> unique_constraint([:org, :sort_order], name: :acs_authority_levels_org_sort_order_index)
  end

  def slugify(label) when is_binary(label) do
    label
    |> String.downcase()
    |> String.trim()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "level"
      slug -> slug
    end
  end

  def slugify(_), do: "level"

  defp normalize_slug(nil), do: nil

  defp normalize_slug(slug) when is_binary(slug) do
    slug |> String.trim() |> String.downcase() |> slugify()
  end

  defp normalize_slug(_), do: nil

  defp trim(nil), do: nil
  defp trim(s) when is_binary(s), do: String.trim(s)
  defp trim(_), do: nil

  defp trim_downcase(nil), do: nil
  defp trim_downcase(s) when is_binary(s), do: s |> String.trim() |> String.downcase()
  defp trim_downcase(_), do: nil
end
