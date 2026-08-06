defmodule Acs.Artifacts.Importer do
  alias Acs.Artifacts.{Ledger, Skill, Spec, TenantTool}
  alias Acs.MCP.ToolLoader
  alias Acs.Memory.Frontmatter
  alias Acs.Orgs.Organization
  alias Acs.Repo
  alias Acs.Specs.Entry

  @default_root "/vaults"

  def import(opts \\ []) do
    root = opts |> Keyword.get(:root, @default_root) |> Path.expand()
    organizations = Repo.all(Organization) |> Map.new(&{&1.slug, &1})
    directories = organization_dirs(root)

    unknown =
      directories |> Enum.map(&elem(&1, 0)) |> Enum.reject(&Map.has_key?(organizations, &1))

    cond do
      directories == [] ->
        {:error, {:artifact_source_not_found, Path.join(root, "orgs")}}

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
            {:error, {:no_artifacts_found, root}}

          {:ok, summary} ->
            {:ok, %{summary | organizations: Enum.sort(summary.organizations)}}

          error ->
            error
        end
    end
  end

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
    artifacts =
      skill_files(directory)
      |> Enum.map(&{:skill, &1})
      |> Kernel.++(spec_files(directory) |> Enum.map(&{:spec, &1}))
      |> Kernel.++(tool_files(directory) |> Enum.map(&{:tool, &1}))

    Enum.reduce_while(artifacts, {:ok, add_organization(summary, organization.slug)}, fn
      {:skill, file}, {:ok, summary} ->
        case skill_artifact(file) do
          {:ok, public_id, snapshot} ->
            import_artifact(organization, :skill, public_id, snapshot, file, summary)

          {:error, reason} ->
            {:halt, artifact_error(:skill, organization.slug, file, reason)}
        end

      {:spec, file}, {:ok, summary} ->
        case spec_artifact(file) do
          {:ok, public_id, snapshot} ->
            import_artifact(organization, :spec, public_id, snapshot, file, summary)

          {:error, reason} ->
            {:halt, artifact_error(:spec, organization.slug, file, reason)}
        end

      {:tool, file}, {:ok, summary} ->
        case tool_artifacts(file, organization.slug, directory) do
          {:ok, tools} ->
            case import_tools(organization, tools, file, summary) do
              {:ok, summary} -> {:cont, {:ok, summary}}
              {:error, _} = error -> {:halt, error}
            end

          {:error, reason} ->
            {:halt, artifact_error(:tool, organization.slug, file, reason)}
        end
    end)
  end

  defp skill_files(directory), do: files(Path.join(directory, "skills"), ["*.md", "**/*.md"])

  defp spec_files(directory),
    do:
      files(Path.join(directory, "specs"), ["*.yaml", "*.yml", "**/*.yaml", "**/*.yml", "**/*.md"])

  defp tool_files(directory), do: files(Path.join(directory, "acstools"), ["*.yaml", "*.yml"])

  defp files(directory, patterns) do
    patterns
    |> Enum.flat_map(&Path.wildcard(Path.join(directory, &1)))
    |> Enum.filter(&File.regular?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp skill_artifact(file) do
    with {:ok, content} <- File.read(file),
         {:ok, frontmatter, body} <- Frontmatter.split(content),
         name when is_binary(name) and name != "" <- Map.get(frontmatter, "name") do
      {:ok, name, Map.put(frontmatter, "content", String.trim(body))}
    else
      nil -> {:error, :missing_name}
      "" -> {:error, :missing_name}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_name}
    end
  end

  defp spec_artifact(file) do
    with {:ok, map} <- spec_map(file),
         entry <- Entry.from_map(map),
         snapshot <- spec_snapshot(entry, map),
         app when is_binary(app) and app != "" <- Map.get(snapshot, "app"),
         id when is_binary(id) and id != "" <- Map.get(snapshot, "id") do
      {:ok, "#{app}/#{id}", snapshot}
    else
      nil -> {:error, :missing_app_or_id}
      "" -> {:error, :missing_app_or_id}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_app_or_id}
    end
  end

  defp spec_map(file) do
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

  defp spec_snapshot(entry, map) do
    entry
    |> Entry.to_map()
    |> preserve_source_timestamp(map, "created_at")
    |> preserve_source_timestamp(map, "updated_at")
  end

  defp preserve_source_timestamp(snapshot, map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> Map.put(snapshot, key, value)
      :error -> Map.delete(snapshot, key)
    end
  end

  defp tool_artifacts(file, slug, directory) do
    with {:ok, config} <- YamlElixir.read_from_file(file),
         :ok <-
           ToolLoader.validate_config(config, {:tenant, slug, Path.join(directory, "acstools")}) do
      app = config["app"]

      {:ok,
       Enum.map(config["tools"], fn tool ->
         name = tool["name"]

         {"#{app}/#{name}",
          %{
            "app" => app,
            "name" => name,
            "description" => tool["description"],
            "category" => tool["category"],
            "definition" => Map.put(config, "tools", [tool]),
            "active" => true
          }}
       end)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_yaml}
    end
  end

  defp import_tools(organization, tools, file, summary) do
    Enum.reduce_while(tools, {:ok, summary}, fn {public_id, snapshot}, {:ok, summary} ->
      import_artifact(organization, :tool, public_id, snapshot, file, summary)
    end)
  end

  defp import_artifact(organization, kind, public_id, snapshot, file, summary) do
    case existing_snapshot(kind, organization.id, public_id) do
      nil ->
        case Ledger.save(kind, public_id, snapshot,
               org: organization,
               operation: "import",
               actor: %{type: "importer", id: "vault_artifact_import"},
               source: "migration",
               message: "Import #{kind} #{public_id}"
             ) do
          {:ok, _} -> {:cont, {:ok, %{summary | imported: summary.imported + 1}}}
          {:error, reason} -> {:halt, artifact_error(kind, organization.slug, file, reason)}
        end

      ^snapshot ->
        {:cont, {:ok, %{summary | skipped: summary.skipped + 1}}}

      _ ->
        {:halt,
         {:error,
          {:conflict,
           %{organization: organization.slug, kind: kind, public_id: public_id, file: file}}}}
    end
  end

  defp existing_snapshot(kind, organization_id, public_id) do
    kind
    |> projection_schema()
    |> Repo.get_by(organization_id: organization_id, public_id: public_id)
    |> case do
      nil -> nil
      projection -> decode_snapshot(projection.snapshot_json)
    end
  end

  defp projection_schema(:skill), do: Skill
  defp projection_schema(:spec), do: Spec
  defp projection_schema(:tool), do: TenantTool

  defp decode_snapshot(snapshot_json) do
    case Jason.decode(snapshot_json) do
      {:ok, snapshot} -> snapshot
      {:error, _} -> :invalid_snapshot
    end
  end

  defp add_organization(summary, slug),
    do: %{summary | organizations: Enum.uniq([slug | summary.organizations])}

  defp artifact_error(kind, organization, file, reason),
    do:
      {:error,
       {:invalid_artifact, %{kind: kind, organization: organization, file: file, reason: reason}}}
end
