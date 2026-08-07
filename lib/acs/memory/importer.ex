defmodule Acs.Memory.Importer do
  @moduledoc """
  Imports vault memory YAML/MD files into the memory ledger.

  In multi-tenant prod the memory ledger (PostgreSQL) is the canonical store —
  there is no vault file system. This importer is the cutover path that reads
  file-canonical memories staged under `<root>/orgs/<slug>/memories/**/*` and
  re-writes them through `Acs.Memory.Ledger.save/2` so each memory becomes a
  proper ledger commit + revision + projection row.

  Layout mirrors `Acs.Artifacts.Importer`: the root defaults to `/vaults` and
  per-org directories are `<root>/orgs/<slug>/memories/`. Unlike the artifact
  importer (which snapshots skills/specs/tools verbatim), the org slug from the
  vault path is always forced onto the memory so files written for one org
  (e.g. local `org: default`) can be staged under any target org's directory.

  Idempotency: an existing company memory whose head revision snapshot equals
  the source memory (ignoring `created_at`/`updated_at`, which the ledger
  normalizes on write) is skipped; one whose snapshot differs halts the whole
  import with `{:conflict, ...}`.

  "Accepted only" filtering (e.g. skipping rejected/stale memories) is a
  STAGING concern: only place the files you want imported under
  `<root>/orgs/<slug>/memories/`.
  """

  alias Acs.Memory.{CompanyMemory, Frontmatter, Ledger, Revision}
  alias Acs.Orgs.Organization
  alias Acs.Repo

  @default_root "/vaults"

  @doc """
  Imports all staged memory files into the memory ledger.

  Returns `{:ok, summary}` where `summary` is `%{imported: count, skipped:
  count, organizations: [slug]}`. Fails closed: unknown org directories, an
  invalid memory file, a snapshot conflict, or an empty source all halt with an
  error tuple.
  """
  def import(opts \\ []) do
    root = opts |> Keyword.get(:root, @default_root) |> Path.expand()
    organizations = Repo.all(Organization) |> Map.new(&{&1.slug, &1})
    directories = organization_dirs(root)

    unknown =
      directories |> Enum.map(&elem(&1, 0)) |> Enum.reject(&Map.has_key?(organizations, &1))

    cond do
      directories == [] ->
        {:error, {:memory_source_not_found, Path.join(root, "orgs")}}

      unknown != [] ->
        {:error, {:unknown_organizations, Enum.sort(unknown)}}

      true ->
        directories
        |> Enum.reduce_while({:ok, empty_summary()}, fn {slug, directory}, {:ok, summary} ->
          organization = Map.fetch!(organizations, slug)

          case import_organization(organization, directory, summary) do
            {:ok, summary} -> {:cont, {:ok, summary}}
            {:error, _} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, %{imported: 0, skipped: 0}} ->
            {:error, {:no_memories_found, root}}

          {:ok, summary} ->
            {:ok, %{summary | organizations: Enum.sort(summary.organizations)}}

          error ->
            error
        end
    end
  end

  @doc """
  Verifies the memory ledger hash chain for the given organizations.
  """
  def verify, do: verify(Repo.all(Organization))

  def verify(%{organizations: organizations}), do: verify(organizations)

  def verify(organizations) when is_list(organizations) do
    organizations
    |> Enum.map(fn
      %Organization{} = organization -> organization.slug
      slug -> slug
    end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn slug, :ok ->
      case Ledger.verify(slug) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, %{organization: slug, reason: reason}}}
      end
    end)
  end

  defp empty_summary, do: %{imported: 0, skipped: 0, organizations: []}

  defp organization_dirs(root) do
    root
    |> Path.join("orgs/*")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.map(&{Path.basename(&1), &1})
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp import_organization(organization, directory, summary) do
    memories = directory |> memory_files() |> Enum.map(&load_memory(&1, organization.slug))

    case Enum.find(memories, fn
           {:ok, _} -> false
           {:error, _} -> true
         end) do
      nil ->
        memories
        |> Enum.map(fn {:ok, memory} -> memory end)
        |> dedupe_by_id()
        |> Enum.reduce_while({:ok, add_organization(summary, organization.slug)}, fn
          memory, {:ok, summary} -> import_memory(organization, memory, summary)
        end)

      {:error, {organization_slug, file, reason}} ->
        {:error, memory_error(organization_slug, file, reason)}
    end
  end

  defp memory_files(directory),
    do:
      files(Path.join(directory, "memories"), [
        "*.yaml",
        "*.yml",
        "**/*.yaml",
        "**/*.yml",
        "**/*.md"
      ])

  defp files(directory, patterns) do
    patterns
    |> Enum.flat_map(&Path.wildcard(Path.join(directory, &1)))
    |> Enum.filter(&File.regular?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp load_memory(file, slug) do
    with {:ok, map} <- memory_map(file),
         map <- Map.put(map, "org", slug),
         :ok <- Acs.Memory.validate(map) do
      {:ok, Acs.Memory.new(map)}
    else
      {:error, reason} -> {:error, {slug, file, reason}}
      _ -> {:error, {slug, file, :invalid_memory}}
    end
  end

  defp memory_map(file) do
    case Path.extname(file) |> String.downcase() do
      ".md" ->
        with {:ok, content} <- File.read(file),
             {:ok, frontmatter, body} <- Frontmatter.split(content) do
          {:ok, Map.put(frontmatter, "content", body)}
        end

      _ ->
        case YamlElixir.read_from_file(file) do
          {:ok, map} when is_map(map) -> {:ok, map}
          {:ok, _} -> {:error, :invalid_yaml}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp dedupe_by_id(memories) do
    memories
    |> Enum.sort_by(fn memory -> -updated_at_unix(memory.updated_at) end)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.id)
  end

  defp updated_at_unix(nil), do: 0

  defp updated_at_unix(updated_at) do
    case DateTime.from_iso8601(updated_at) do
      {:ok, datetime, _} -> DateTime.to_unix(datetime)
      _ -> 0
    end
  end

  defp import_memory(organization, memory, summary) do
    case existing_snapshot(organization, memory) do
      nil ->
        case Ledger.save(memory,
               org: organization.slug,
               operation: "import",
               actor: %{type: "importer", id: "vault_memory_import"},
               source: "migration",
               message: "Import memory #{memory.id}"
             ) do
          {:ok, _} -> {:cont, {:ok, %{summary | imported: summary.imported + 1}}}
          {:error, reason} -> {:halt, memory_error(organization.slug, memory.id, reason)}
        end

      :match ->
        {:cont, {:ok, %{summary | skipped: summary.skipped + 1}}}

      :conflict ->
        {:halt,
         {:error,
          {:conflict,
           %{
             organization: organization.slug,
             memory_id: memory.id,
             file: memory.id
           }}}}
    end
  end

  # Returns nil when no company memory exists yet, :match when the existing
  # head revision snapshot equals the source (ignoring ledger-normalized
  # timestamps), or :conflict when a company memory exists with a different head.
  defp existing_snapshot(organization, memory) do
    case Repo.get_by(CompanyMemory, organization_id: organization.id, public_id: memory.id) do
      nil ->
        nil

      %{head_revision_id: nil} ->
        nil

      %{head_revision_id: head_revision_id} ->
        revision = Repo.get!(Revision, head_revision_id)

        source =
          memory
          |> Acs.Memory.to_yaml_map()
          |> Map.drop(["created_at", "updated_at"])

        stored =
          revision.snapshot_json
          |> Jason.decode!()
          |> Map.drop(["created_at", "updated_at"])

        if source == stored, do: :match, else: :conflict
    end
  end

  defp add_organization(summary, slug),
    do: %{summary | organizations: Enum.uniq([slug | summary.organizations])}

  defp memory_error(organization, file, reason),
    do: {:error, {:invalid_memory, %{organization: organization, file: file, reason: reason}}}
end
