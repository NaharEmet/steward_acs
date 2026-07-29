defmodule Acs.Skills.Store do
  @moduledoc """
  File-based skill store. Skills are Markdown files with YAML frontmatter.

  Skills live under `priv/skills/` by default or `<vault>/orgs/<org>/skills/`
  when an Obsidian vault is configured. Files are discovered recursively so external
  tools may organize skills into directories. Vault files take precedence over
  bundled files with the same relative path.

  Skill content may be saved via MCP `skill_save` (lands as `status: proposed`)
  or authored externally. Governance/audit fields can be patched on frontmatter.
  """

  @builtin_dir "priv/skills"
  @governance_statuses ~w(proposed approved rejected)

  def skill_dir, do: Acs.Org.skills_dir()

  def all_skills do
    search_dirs()
    |> Enum.flat_map(fn root ->
      Enum.map(skill_paths(root), fn path ->
        {Path.rootname(Path.relative_to(path, root)), path, root}
      end)
    end)
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.map(fn {_id, path, root} -> parse_skill_file(path, root) end)
    |> Enum.reject(&is_nil/1)
  end

  def list_skills(tag \\ nil) do
    all_skills()
    |> Enum.filter(fn skill -> is_nil(tag) || tag in (skill.tags || []) end)
    |> Enum.map(&skill_metadata/1)
  end

  def list_skills_by_scope(scope_path) do
    all_skills()
    |> Enum.filter(fn skill ->
      Enum.any?(skill.scope_paths || [], &String.starts_with?(scope_path, &1))
    end)
    |> Enum.map(&skill_metadata/1)
  end

  def get_skill(id_or_name) do
    all_skills()
    |> Enum.find(fn skill -> skill.id == id_or_name || skill.name == id_or_name end)
  end

  def search_skills(query) do
    query = String.downcase(query)

    all_skills()
    |> Enum.filter(fn skill ->
      Enum.any?(
        [skill.name, skill.description, skill.content, Enum.join(skill.tags || [], " ")],
        fn value ->
          String.contains?(String.downcase(value || ""), query)
        end
      )
    end)
  end

  def update_status(id, status, reviewer \\ "human")

  def update_status(id, status, reviewer) when status in @governance_statuses do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    fields =
      %{"status" => status, "reviewed_by" => reviewer, "reviewed_at" => now}
      |> maybe_add_decision_fields(status, reviewer, now)

    update_frontmatter(id, fields)
  end

  def update_status(_id, _status, _reviewer), do: {:error, :invalid_status}

  def write_audit_fields(id_or_name, fields) do
    case find_skill(id_or_name) do
      nil -> {:error, :not_found}
      skill -> update_file_frontmatter(skill.file, fields)
    end
  end

  @doc """
  Create or overwrite a skill markdown file in the org skills dir.

  Opts keys (string or atom): `description`, `when_to_use`, `tags`, `scope_paths`, `status`, `proposed_by`.
  Defaults to `status: \"proposed\"`.
  """
  def save_skill(name, content, opts \\ []) when is_binary(name) and is_binary(content) do
    opts = normalize_opts(opts)
    dir = skill_dir()
    safe = safe_name(name)
    path = Path.join(dir, "#{safe}.md")

    with true <- Acs.Org.safe_path?(dir, path),
         :ok <- File.mkdir_p(dir) do
      meta = %{
        "name" => name,
        "description" => opts["description"],
        "when_to_use" => opts["when_to_use"],
        "tags" => opts["tags"] || [],
        "scope_paths" => opts["scope_paths"] || [],
        "status" => opts["status"] || "proposed",
        "proposed_by" => opts["proposed_by"]
      }

      frontmatter =
        meta
        |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
        |> Enum.map(fn {k, v} -> "#{k}: #{encode_yaml_value(v)}" end)
        |> Enum.join("\n")

      body = String.trim_trailing(content) <> "\n"
      File.write!(path, "---\n#{frontmatter}\n---\n\n#{body}")
      {:ok, %{name: name, id: safe, path: path, status: meta["status"]}}
    else
      false -> {:error, :unsafe_path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_opts(opts) when is_list(opts), do: Map.new(opts, fn {k, v} -> {to_string(k), v} end)
  defp normalize_opts(opts) when is_map(opts), do: Map.new(opts, fn {k, v} -> {to_string(k), v} end)

  defp safe_name(name) do
    name
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "skill"
      other -> other
    end
  end

  def context_for_audit(exclude_name, limit \\ 5) do
    list_skills()
    |> Enum.reject(fn meta -> meta["name"] == exclude_name end)
    |> Enum.take(limit)
    |> Enum.map(fn meta ->
      case get_skill(meta["name"]) do
        nil -> nil
        skill -> %{name: skill.name, description: skill.description, tags: skill.tags}
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  def skill_dir(org) when is_binary(org), do: Acs.Org.skills_dir(org)

  defp builtin_dir, do: Path.join(Application.app_dir(:steward_acs), @builtin_dir)

  defp search_dirs do
    [skill_dir() | Acs.Org.legacy_skills_dirs() ++ [builtin_dir()]]
    |> Enum.uniq()
  end

  defp skill_paths(root) do
    [Path.join(root, "*.md"), Path.join(root, "**/*.md")]
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
    |> Enum.reject(fn path ->
      legacy_partition_container?(root) and
        match?(["orgs" | _], Path.split(Path.relative_to(path, root)))
    end)
    |> Enum.filter(fn path ->
      if root == builtin_dir() do
        File.regular?(path)
      else
        Acs.Org.safe_path?(root, path) and
          match?({:ok, %File.Stat{type: :regular}}, File.lstat(path))
      end
    end)
  end

  defp legacy_partition_container?(root) do
    case Acs.Org.vault_base() do
      nil -> false
      base -> Path.expand(root) == Path.expand(Path.join(base, "skills"))
    end
  end

  defp parse_skill_file(path, root) do
    with {:ok, content} <- File.read(path),
         {:ok, frontmatter, body} <- split_frontmatter(content),
         {:ok, metadata} <- parse_yaml_frontmatter(frontmatter) do
      relative = Path.relative_to(path, root)
      id = Path.rootname(relative)

      %{
        id: id,
        name: scalar(metadata["name"]) || Path.basename(id),
        description: scalar(metadata["description"]),
        tags: string_list(metadata["tags"]),
        scope_paths: string_list(metadata["scope_paths"]),
        content: String.trim(body),
        status: normalize_status(metadata["status"]),
        group: group_for(id),
        file: path,
        metadata: metadata
      }
    else
      _ -> nil
    end
  end

  defp update_frontmatter(id, fields) do
    case Enum.find(all_skills(), &(&1.id == id)) do
      nil -> {:error, :not_found}
      skill -> update_file_frontmatter(skill.file, fields)
    end
  end

  defp update_file_frontmatter(path, fields) do
    with {:ok, content} <- File.read(path),
         {:ok, frontmatter, body} <- split_frontmatter(content),
         {:ok, metadata} <- parse_yaml_frontmatter(frontmatter),
         :ok <- ensure_primary_copy(path, content),
         target_path = primary_path_for(path),
         true <- Acs.Org.safe_path?(skill_dir(), target_path),
         updated_frontmatter = patch_frontmatter(frontmatter, metadata, stringify_keys(fields)),
         :ok <- File.mkdir_p(Path.dirname(target_path)),
         true <- Acs.Org.safe_path?(skill_dir(), target_path),
         :ok <- File.write(target_path, "---\n#{updated_frontmatter}\n---\n#{body}") do
      :ok
    end
  end

  defp ensure_primary_copy(path, content) do
    target_path = primary_path_for(path)

    cond do
      target_path == path ->
        :ok

      File.exists?(target_path) ->
        :ok

      true ->
        with :ok <- File.mkdir_p(Path.dirname(target_path)),
             :ok <- File.write(target_path, content) do
          :ok
        end
    end
  end

  defp primary_path_for(path) do
    primary = skill_dir()

    Enum.find_value(search_dirs(), path, fn root ->
      if root != primary and path_within?(path, root) do
        Path.join(primary, Path.relative_to(path, root))
      end
    end)
  end

  defp path_within?(path, root) do
    relative = Path.relative_to(path, root)
    relative != path && relative != ".." && !String.starts_with?(relative, "../")
  end

  defp patch_frontmatter(frontmatter, metadata, fields) do
    Enum.reduce(fields, frontmatter, fn {key, value}, yaml ->
      replacement = "#{key}: #{encode_yaml_value(value)}"

      if Map.has_key?(metadata, key) do
        Regex.replace(~r/^#{Regex.escape(key)}\s*:.*$/m, yaml, replacement, global: false)
      else
        String.trim_trailing(yaml) <> "\n" <> replacement
      end
    end)
  end

  defp find_skill(id_or_name) do
    Enum.find(all_skills(), &(&1.id == id_or_name || &1.name == id_or_name))
  end

  defp skill_metadata(skill) do
    skill.metadata
    |> Map.put("name", skill.name)
    |> Map.put("status", skill.status)
    |> Map.put("id", skill.id)
    |> Map.put("file", skill.file)
  end

  defp maybe_add_decision_fields(fields, "approved", reviewer, now),
    do: Map.merge(fields, %{"approved_by" => reviewer, "approved_at" => now})

  defp maybe_add_decision_fields(fields, "rejected", reviewer, now),
    do: Map.merge(fields, %{"rejected_by" => reviewer, "rejected_at" => now})

  defp maybe_add_decision_fields(fields, _status, _reviewer, _now), do: fields

  defp stringify_keys(fields),
    do: Map.new(fields, fn {key, value} -> {to_string(key), value} end)

  defp encode_yaml_value(nil), do: "null"
  defp encode_yaml_value(value) when is_integer(value), do: Integer.to_string(value)
  defp encode_yaml_value(value) when is_boolean(value), do: to_string(value)

  defp encode_yaml_value(value) when is_list(value),
    do: "[#{Enum.map_join(value, ", ", &encode_yaml_value/1)}]"

  defp encode_yaml_value(value) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")

    ~s("#{escaped}")
  end

  defp encode_yaml_value(value), do: encode_yaml_value(inspect(value))

  defp split_frontmatter(content) do
    case Regex.run(~r/\A---\r?\n(.*?)\r?\n---\r?\n?(.*)\z/s, content) do
      [_, frontmatter, body] -> {:ok, frontmatter, body}
      _ -> {:error, :invalid_frontmatter}
    end
  end

  defp parse_yaml_frontmatter(yaml) do
    case YamlElixir.read_from_string(String.trim(yaml)) do
      {:ok, metadata} when is_map(metadata) -> {:ok, metadata}
      _ -> parse_legacy_frontmatter(yaml)
    end
  rescue
    _ -> parse_legacy_frontmatter(yaml)
  end

  defp parse_legacy_frontmatter(yaml) do
    metadata =
      yaml
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(&1, [" ", "\t"]))
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, ":", parts: 2) do
          [key, value] -> Map.put(acc, String.trim(key), parse_legacy_value(String.trim(value)))
          _ -> acc
        end
      end)

    if metadata == %{}, do: {:error, :invalid_frontmatter}, else: {:ok, metadata}
  end

  defp parse_legacy_value("[" <> rest) do
    rest
    |> String.trim_trailing("]")
    |> String.split(",", trim: true)
    |> Enum.map(fn value -> value |> String.trim() |> String.trim("\"") |> String.trim("'") end)
  end

  defp parse_legacy_value(value), do: value |> String.trim("\"") |> String.trim("'")

  defp normalize_status(status) when status in @governance_statuses, do: status
  defp normalize_status(_status), do: "proposed"

  defp scalar(value) when is_binary(value), do: value
  defp scalar(_value), do: nil

  defp string_list(value) when is_list(value), do: Enum.filter(value, &is_binary/1)
  defp string_list(_value), do: []

  defp group_for(id) do
    case Path.dirname(id) do
      "." -> "root"
      directory -> directory
    end
  end
end
