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
    dir = skill_dir()
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{safe_name(name)}.md")
    tags_yaml = if tags != [], do: "\ntags: #{inspect(tags)}", else: ""
    desc_yaml = if description, do: "\ndescription: #{description}", else: ""

    frontmatter = "---\nname: #{name}#{desc_yaml}#{tags_yaml}\n---\n\n"
    File.write!(path, frontmatter <> content)
    {:ok, name}
  end

  def write_audit_fields(name, fields) do
    path = Path.join(skill_dir(), "#{safe_name(name)}.md")

    case File.read(path) do
      {:ok, content} ->
        case String.split(content, "---", parts: 3) do
          ["", frontmatter, body] ->
            existing = parse_yaml_frontmatter(frontmatter)
            updated = Map.merge(existing, Map.new(fields, fn {k, v} -> {to_string(k), v} end))

            new_frontmatter =
              updated
              |> Enum.map(fn {k, v} -> "#{k}: #{format_yaml_value(v)}" end)
              |> Enum.join("\n")

            File.write!(path, "---\n#{new_frontmatter}\n---#{body}")
            :ok

          _ ->
            {:error, "invalid frontmatter"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp format_yaml_value(value) when is_integer(value), do: Integer.to_string(value)
  defp format_yaml_value(value) when is_list(value), do: inspect(value)
  defp format_yaml_value(value) when is_binary(value), do: value
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
    case String.split(content, "---", parts: 3) do
      ["", frontmatter, body] ->
        meta = parse_yaml_frontmatter(String.trim(frontmatter))
        {meta, String.trim_leading(body)}

      _ ->
        nil
    end
  end

  defp parse_yaml_frontmatter(yaml) do
    yaml
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 != ""))
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [key, val] ->
          trimmed = String.trim(val)
          parsed = try_parse_list(trimmed)
          Map.put(acc, String.trim(key), parsed)

        _ ->
          acc
      end
    end)
  end

  defp try_parse_list(value) do
    if String.starts_with?(value, "[") and String.ends_with?(value, "]") do
      value
      |> String.trim_leading("[")
      |> String.trim_trailing("]")
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.map(fn s -> s |> String.trim("\"") |> String.trim("'") end)
    else
      value
    end
  end
end
