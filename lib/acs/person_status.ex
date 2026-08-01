defmodule Acs.PersonStatus do
  @moduledoc """
  Org-scoped directory of people (email/name → job status + data authority level).

  `rank` stores an authority **slug** from the org catalog (`Acs.AuthorityLevels`).
  Legacy defaults: `high` | `elevated` | `standard` (labels Executive / Senior / Standard).
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Acs.AuthorityLevels
  alias Acs.Repo

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "acs_person_statuses" do
    field :org, :string
    field :email, :string
    field :name, :string
    field :status, :string
    field :rank, :string, default: "standard"
    field :updated_by, :string

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc "Legacy helper — true when the person's level is the highest sort_order band (1)."
  def high_rank?(%__MODULE__{rank: rank, org: org}) when is_binary(rank) do
    AuthorityLevels.sort_order_for(org || Acs.Org.current(), rank) == 1
  end

  def high_rank?(_), do: false

  def changeset(person, attrs) do
    person
    |> cast(attrs, [:org, :email, :name, :status, :rank, :updated_by])
    |> update_change(:email, &normalize_email/1)
    |> update_change(:name, &normalize_name/1)
    |> update_change(:status, &trim_or_nil/1)
    |> update_change(:rank, &normalize_rank_slug/1)
    |> validate_required([:org, :name, :status, :rank])
    |> validate_rank_in_catalog()
    |> validate_email_or_name()
    |> unique_constraint([:org, :email], name: :acs_person_statuses_org_email_index)
  end

  @doc "Lookup by email (preferred) or name within org."
  def get(org, opts) when is_binary(org) and is_list(opts) do
    email = opts |> Keyword.get(:email) |> normalize_email()
    name = opts |> Keyword.get(:name) |> normalize_name()

    cond do
      is_binary(email) ->
        Repo.one(from p in __MODULE__, where: p.org == ^org and p.email == ^email)

      is_binary(name) ->
        Repo.one(from p in __MODULE__, where: p.org == ^org and p.name == ^name)

      true ->
        nil
    end
  end

  @doc "Upsert person status. Identity is email when present, else name. Rank may be slug or label."
  def upsert(attrs) when is_map(attrs) do
    org = attrs["org"] || attrs[:org] || Acs.Org.current()
    email = normalize_email(attrs["email"] || attrs[:email])
    name = normalize_name(attrs["name"] || attrs[:name])
    AuthorityLevels.ensure_defaults!(org)

    existing =
      cond do
        is_binary(email) -> get(org, email: email)
        is_binary(name) -> get(org, name: name)
        true -> nil
      end

    base = existing || %__MODULE__{org: org}

    rank_input = attrs["rank"] || attrs[:rank] || (existing && existing.rank) || "standard"
    rank = resolve_rank_slug(org, rank_input) || "standard"

    params = %{
      "org" => org,
      "email" => email,
      "name" => name || (existing && existing.name),
      "status" => attrs["status"] || attrs[:status],
      "rank" => rank,
      "updated_by" => attrs["updated_by"] || attrs[:updated_by]
    }

    base
    |> changeset(params)
    |> Repo.insert_or_update()
  end

  def to_map(%__MODULE__{} = p) do
    level = AuthorityLevels.get_by_slug(p.org, p.rank)

    %{
      id: p.id,
      org: p.org,
      email: p.email,
      name: p.name,
      status: p.status,
      rank: p.rank,
      rank_label: level && level.label,
      authority_sort_order: level && level.sort_order,
      updated_by: p.updated_by,
      updated_at: p.updated_at
    }
  end

  def ranks(org \\ Acs.Org.current()) do
    AuthorityLevels.list(org) |> Enum.map(& &1.slug)
  end

  defp validate_rank_in_catalog(changeset) do
    org = get_field(changeset, :org)
    rank = get_field(changeset, :rank)

    if is_binary(org) and is_binary(rank) and AuthorityLevels.get_by_slug(org, rank) do
      changeset
    else
      allowed =
        if is_binary(org),
          do: AuthorityLevels.list(org) |> Enum.map(&"#{&1.label} (#{&1.slug})") |> Enum.join(", "),
          else: ""

      add_error(changeset, :rank, "must be an org authority level#{if allowed != "", do: ": #{allowed}", else: ""}")
    end
  end

  defp validate_email_or_name(changeset) do
    email = get_field(changeset, :email)
    name = get_field(changeset, :name)

    if is_nil(email) and (is_nil(name) or name == "") do
      add_error(changeset, :name, "email or name is required")
    else
      changeset
    end
  end

  defp resolve_rank_slug(org, input) when is_binary(input) do
    case AuthorityLevels.resolve(org, input) do
      %{slug: slug} -> slug
      nil -> normalize_rank_slug(input)
    end
  end

  defp resolve_rank_slug(_, _), do: nil

  defp normalize_email(nil), do: nil

  defp normalize_email(email) when is_binary(email) do
    email |> String.trim() |> String.downcase() |> empty_to_nil()
  end

  defp normalize_email(_), do: nil

  defp normalize_name(nil), do: nil

  defp normalize_name(name) when is_binary(name) do
    name |> String.trim() |> empty_to_nil()
  end

  defp normalize_name(_), do: nil

  defp normalize_rank_slug(nil), do: "standard"

  defp normalize_rank_slug(rank) when is_binary(rank) do
    Acs.AuthorityLevel.slugify(rank)
  end

  defp normalize_rank_slug(_), do: "standard"

  defp trim_or_nil(nil), do: nil
  defp trim_or_nil(s) when is_binary(s), do: s |> String.trim() |> empty_to_nil()
  defp trim_or_nil(_), do: nil

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(v), do: v
end
