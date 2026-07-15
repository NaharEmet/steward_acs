defmodule Acs.Orgs do
  @moduledoc """
  Org provisioning and lookup from `priv/orgs.yaml`.

  Orgs are loaded from the YAML file on every call — no in-memory cache.
  Writing a new org via `create/1` persists to the file immediately.
  """
  defstruct [:id, :name, :slug, :subdomain, :plan]

  @reserved_subdomains ~w(www obsidian api)
  @slug_regex ~r/^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/

  def list_all do
    load_orgs()
  end

  def get_by_slug(slug) when is_binary(slug) do
    load_orgs() |> Enum.find(&(&1.slug == slug))
  end

  def get_by_subdomain(subdomain) when is_binary(subdomain) do
    load_orgs() |> Enum.find(&(&1.subdomain == subdomain))
  end

  def resolve_subdomain(subdomain) do
    slug = normalize_subdomain(subdomain)

    cond do
      slug in @reserved_subdomains ->
        {:error, :reserved_subdomain}

      Acs.Org.multi_tenant?() ->
        case get_by_subdomain(slug) do
          %__MODULE__{slug: org_slug} -> {:ok, org_slug}
          nil -> {:error, :unknown_org}
        end

      true ->
        {:ok, slug}
    end
  end

  def create(attrs) do
    name = attrs[:name] || attrs["name"]
    slug = attrs[:slug] || attrs["slug"]
    subdomain = attrs[:subdomain] || attrs["subdomain"] || slug
    plan = attrs[:plan] || attrs["plan"] || "free"

    errors =
      []
      |> then(fn e ->
        if is_nil(name) or name == "", do: [{:name, {"can't be blank", []}} | e], else: e
      end)
      |> then(fn e ->
        if is_nil(slug) or slug == "", do: [{:slug, {"can't be blank", []}} | e], else: e
      end)
      |> then(fn e ->
        if not Regex.match?(@slug_regex, slug), do: [{:slug, {"invalid format", []}} | e], else: e
      end)
      |> then(fn e ->
        if not Regex.match?(@slug_regex, subdomain),
          do: [{:subdomain, {"invalid format", []}} | e],
          else: e
      end)
      |> then(fn e ->
        if Enum.any?(load_orgs(), &(&1.slug == slug)),
          do: [{:slug, {"has already been taken", []}} | e],
          else: e
      end)
      |> then(fn e ->
        if Enum.any?(load_orgs(), &(&1.subdomain == subdomain)),
          do: [{:subdomain, {"has already been taken", []}} | e],
          else: e
      end)
      |> Enum.reverse()

    if errors == [] do
      org = %__MODULE__{
        id: slug,
        name: name,
        slug: slug,
        subdomain: subdomain,
        plan: plan
      }

      orgs = load_orgs() ++ [org]
      save_orgs(orgs)
      {:ok, org}
    else
      {:error, errors}
    end
  end

  def ensure_default! do
    case get_by_slug("default") do
      %__MODULE__{} = org -> org
      nil -> elem(create(%{name: "Default", slug: "default", subdomain: "default"}), 1)
    end
  end

  defp orgs_path do
    Application.get_env(:steward_acs, :orgs_file) ||
      bundled_orgs_path()
  end

  defp load_orgs do
    path = orgs_path()
    bundled_path = bundled_orgs_path()

    case read_orgs(path) do
      [] when path != bundled_path -> read_orgs(bundled_path)
      orgs -> orgs
    end
  end

  defp read_orgs(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, %{"orgs" => orgs_map}} when is_map(orgs_map) ->
        orgs_map
        |> Enum.map(fn {_slug, attrs} ->
          a = if is_map(attrs), do: attrs, else: %{}

          %__MODULE__{
            id: Map.get(a, "slug"),
            name: Map.get(a, "name"),
            slug: Map.get(a, "slug"),
            subdomain: Map.get(a, "subdomain"),
            plan: Map.get(a, "plan", "free")
          }
        end)
        |> Enum.sort_by(& &1.slug)

      _ ->
        []
    end
  end

  defp save_orgs(orgs) do
    yaml = encode_orgs(orgs)
    tmp = orgs_path() <> ".tmp"
    File.mkdir_p!(Path.dirname(tmp))
    File.write!(tmp, yaml)
    File.rename!(tmp, orgs_path())
  end

  defp bundled_orgs_path, do: Application.app_dir(:steward_acs, "priv/orgs.yaml")

  defp encode_orgs(orgs) do
    header = "orgs:"

    entries =
      orgs
      |> Enum.sort_by(& &1.slug)
      |> Enum.flat_map(fn org ->
        [
          "  #{org.slug}:",
          "    name: #{org.name}",
          "    slug: #{org.slug}",
          "    subdomain: #{org.subdomain}",
          "    plan: #{org.plan}"
        ]
      end)

    Enum.join([header | entries], "\n") <> "\n"
  end

  defp normalize_subdomain(nil), do: "default"
  defp normalize_subdomain(""), do: "default"
  defp normalize_subdomain("www"), do: "default"
  defp normalize_subdomain(subdomain), do: subdomain
end
