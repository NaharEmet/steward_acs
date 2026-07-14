defmodule Acs.Skills.Store do
  @moduledoc """
  File-based skill store. Skills are Markdown files with YAML frontmatter.

  Skills live under `priv/skills/` by default or `<vault>/skills/` when an
  Obsidian vault is configured. Files are discovered recursively so external
  tools may organize skills into directories. Vault files take precedence over
  bundled files with the same relative path.

  Skill content is authored outside Steward. This store only updates governance
  and audit fields in existing YAML frontmatter.
  """

  @builtin_dir "priv/skills"
  @governance_statuses ~w(proposed approved rejected)

  def skill_dir do
    obsidian_path = Application.get_env(:steward_acs, :obsidian_vault_path)

    if is_binary(obsidian_path) and obsidian_path != "" do
      Path.join(obsidian_path, "skills")
    else
      Path.join(Application.app_dir(:steward_acs), @builtin_dir)
    end
  end

  def all_skills do
    search_dirs()
    |> Enum.flat_map(&skill_files/1)
    |> Enum.uniq_by(& &1.id)
  end

  def list_skills(tag \\ nil) do
    all_skills()
    |> Enum.filter(fn skill -> is_nil(tag) || tag in (skill.tags || []) end)
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

  defp builtin_dir, do: Path.join(Application.app_dir(:steward_acs), @builtin_dir)

  defp search_dirs do
    primary = skill_dir()
    fallback = builtin_dir()
    if primary == fallback, do: [primary], else: [primary, fallback]
  end

  defp skill_files(root) do
    [Path.join(root, "*.md"), Path.join(root, "**/*.md")]
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
    |> Enum.map(&parse_skill_file(&1, root))
    |> Enum.reject(&is_nil/1)
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
         updated_frontmatter = patch_frontmatter(frontmatter, metadata, stringify_keys(fields)),
         :ok <- File.mkdir_p(Path.dirname(target_path)),
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
    builtin = builtin_dir()

    if skill_dir() != builtin && path_within?(path, builtin) do
      Path.join(skill_dir(), Path.relative_to(path, builtin))
    else
      path
    end
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
