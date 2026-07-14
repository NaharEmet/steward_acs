defmodule Acs.Skills.Store do
  @moduledoc """
  File-based skill store. Each skill is a markdown file with YAML frontmatter.

  Skills live in `priv/skills/` by default. When `OBSIDIAN_VAULT_PATH` is
  configured, they also live in `<vault>/skills/` for Obsidian sync — same
  pattern as specs and memories.

  Reading searches both locations (vault takes priority). Writing targets
  the configured primary directory only.
  """
  @builtin_dir "priv/skills"

  def skill_dir do
    obsidian_path = Application.get_env(:steward_acs, :obsidian_vault_path)

    if is_binary(obsidian_path) and obsidian_path != "" do
      Path.join(obsidian_path, "skills")
    else
      Path.join(Application.app_dir(:steward_acs), @builtin_dir)
    end
  end

  defp builtin_dir do
    Path.join(Application.app_dir(:steward_acs), @builtin_dir)
  end

  defp search_dirs do
    primary = skill_dir()
    fallback = builtin_dir()
    if primary == fallback, do: [primary], else: [primary, fallback]
  end

  def list_skills(tag \\ nil) do
    search_dirs()
    |> Enum.flat_map(fn dir ->
      Path.wildcard(Path.join(dir, "*.md"))
      |> Enum.map(&load_frontmatter/1)
      |> Enum.reject(&is_nil/1)
    end)
    |> Enum.uniq_by(fn meta -> meta["name"] end)
    |> Enum.filter(fn meta ->
      tag == nil || tag in (meta["tags"] || [])
    end)
  end

  def get_skill(name) do
    safe = safe_name(name)

    search_dirs()
    |> Enum.find_value(fn dir ->
      path = Path.join(dir, "#{safe}.md")

      case File.read(path) do
        {:ok, content} -> parse_skill(content)
        {:error, _} -> nil
      end
    end)
  end

  def search_skills(query) do
    q = String.downcase(query)

    search_dirs()
    |> Enum.flat_map(fn dir ->
      Path.wildcard(Path.join(dir, "*.md"))
      |> Enum.map(&parse_skill_file/1)
      |> Enum.reject(&is_nil/1)
    end)
    |> Enum.uniq_by(fn skill -> skill.name end)
    |> Enum.filter(fn skill ->
      String.contains?(String.downcase(skill.name), q) or
        String.contains?(String.downcase(skill.description || ""), q) or
        String.contains?(String.downcase(skill.content), q) or
        Enum.any?(skill.tags || [], fn t -> String.contains?(String.downcase(t), q) end)
    end)
  end

  def save_skill(name, content, tags \\ [], description \\ nil) do
    with :ok <- validate_skill_fields(name, tags, description),
         :ok <- File.mkdir_p(skill_dir()),
         :ok <- write_skill(name, content, tags, description) do
      {:ok, name}
    end
  end

  def writable_skill?(name) do
    Path.join(skill_dir(), "#{safe_name(name)}.md")
    |> File.exists?()
  end

  def delete_skill(name) do
    filename = "#{safe_name(name)}.md"
    primary_path = Path.join(skill_dir(), filename)
    fallback_path = Path.join(builtin_dir(), filename)

    cond do
      File.exists?(primary_path) -> File.rm(primary_path)
      primary_path != fallback_path && File.exists?(fallback_path) -> {:error, :read_only}
      true -> {:error, :not_found}
    end
  end

  def write_audit_fields(name, fields) do
    path = Path.join(skill_dir(), "#{safe_name(name)}.md")

    case File.read(path) do
      {:ok, content} ->
        case split_frontmatter(content) do
          {:ok, frontmatter, body} ->
            existing = parse_yaml_frontmatter(frontmatter)
            updated = Map.merge(existing, Map.new(fields, fn {k, v} -> {to_string(k), v} end))

            new_frontmatter =
              updated
              |> Enum.map(fn {k, v} -> "#{k}: #{format_yaml_value(v)}" end)
              |> Enum.join("\n")

            File.write!(path, "---\n#{new_frontmatter}\n---\n#{body}")
            :ok

          :error ->
            {:error, "invalid frontmatter"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_skill(name, content, tags, description) do
    path = Path.join(skill_dir(), "#{safe_name(name)}.md")

    description_line =
      if description, do: "\ndescription: #{encode_yaml_scalar(description)}", else: ""

    tags_yaml = Enum.map_join(tags, ", ", &encode_yaml_scalar/1)

    frontmatter =
      "name: #{encode_yaml_scalar(name)}#{description_line}\ntags: [#{tags_yaml}]"

    File.write(path, "---\n#{frontmatter}\n---\n\n#{content}")
  end

  defp encode_yaml_scalar(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")

    ~s("#{escaped}")
  end

  defp validate_skill_fields(name, tags, description)
       when is_binary(name) and is_list(tags) and (is_binary(description) or is_nil(description)) do
    if Enum.all?(tags, &is_binary/1), do: :ok, else: {:error, :invalid_fields}
  end

  defp validate_skill_fields(_name, _tags, _description), do: {:error, :invalid_fields}

  defp format_yaml_value(value) when is_integer(value), do: Integer.to_string(value)

  defp format_yaml_value(value) when is_list(value),
    do: "[#{Enum.map_join(value, ", ", &encode_yaml_scalar/1)}]"

  defp format_yaml_value(value) when is_binary(value), do: encode_yaml_scalar(value)
  defp format_yaml_value(value), do: Kernel.inspect(value)

  defp safe_name(name) do
    name |> String.downcase() |> String.replace(~r/[^a-z0-9_-]/, "_")
  end

  defp load_frontmatter(path) do
    case File.read(path) do
      {:ok, content} ->
        case parse_frontmatter(content) do
          {meta, _body} -> Map.put(meta, "file", path)
          nil -> nil
        end

      {:error, _} ->
        nil
    end
  end

  defp parse_skill_file(path) do
    case File.read(path) do
      {:ok, content} -> parse_skill(content)
      {:error, _} -> nil
    end
  end

  defp parse_skill(content) do
    case parse_frontmatter(content) do
      {meta, body} ->
        %{
          name: meta["name"] || Path.rootname(Path.basename(meta["file"] || "")),
          description: meta["description"],
          tags: meta["tags"] || [],
          content: String.trim(body)
        }

      nil ->
        nil
    end
  end

  defp parse_frontmatter(content) do
    case split_frontmatter(content) do
      {:ok, frontmatter, body} ->
        meta = parse_yaml_frontmatter(String.trim(frontmatter))
        {meta, String.trim_leading(body)}

      :error ->
        nil
    end
  end

  defp split_frontmatter(content) do
    case Regex.run(~r/\A---\r?\n(.*?)\r?\n---\r?\n?(.*)\z/s, content) do
      [_, frontmatter, body] -> {:ok, frontmatter, body}
      _ -> :error
    end
  end

  defp parse_yaml_frontmatter(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, metadata} when is_map(metadata) -> metadata
      _ -> %{}
    end
  rescue
    _ -> %{}
  end
end
