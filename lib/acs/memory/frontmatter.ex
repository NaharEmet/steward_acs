defmodule Acs.Memory.Frontmatter do
  @moduledoc """
  Parses Markdown files with YAML frontmatter (delimited by `---`).

  Used to read and write `.md` memory files created by Obsidian or other
  Markdown-aware tools. Handles the `---\\n...\\n---\\n<body>` format where
  the frontmatter block is valid YAML and the body is Markdown text.

  Only recognizes frontmatter at the very start of the file. If the first
  three bytes are not `---`, the file is treated as a body-only entry
  (no frontmatter — returns an empty map + the full content as body).

  Body content may itself contain `---` sequences (e.g., YAML examples,
  horizontal rules); the parser stops looking at the first unescaped
  closing `---` boundary.
  """

  @type parse_result ::
          {:ok, frontmatter :: map(), body :: String.t()}
          | {:error, reason :: String.t()}

  @doc """
  Splits a Markdown+frontmatter file into its frontmatter map and body string.

  Returns `{:ok, frontmatter, body}` on success, or `{:error, reason}` if the
  frontmatter block is syntactically present but could not be parsed as YAML.

  If the file does not start with `---`, the entire content is returned as the
  body with an empty frontmatter map — this supports plain Markdown documents.
  """
  @spec split(binary()) :: parse_result()
  def split(content) when is_binary(content) do
    case String.starts_with?(content, "---") do
      true -> do_split_frontmatter(content)
      false -> {:ok, %{}, content}
    end
  end

  # Split when the file DOES start with `---`.
  defp do_split_frontmatter(content) do
    # Remove the leading "---\n"
    after_opening = String.replace_prefix(content, "---", "")
    after_opening = String.trim_leading(after_opening, "\n")

    # Find the first `\n---\n` boundary that is NOT inside a code fence or
    # preceded by a backslash escape. We look for the pattern: newline + --- + newline.
    case find_closing_boundary(after_opening) do
      {:found, frontmatter_text, body} ->
        parse_frontmatter(frontmatter_text, body)

      {:not_found, _rest} ->
        # No closing boundary — treat the entire thing as body (frontmatter
        # was opened but never closed, so it's not valid frontmatter).
        {:ok, %{}, content}
    end
  end

  # Walk through the content line by line looking for a standalone `---` line
  # that is not inside a code fence (```) and is not escaped (`\---`).
  defp find_closing_boundary(text) do
    lines = String.split(text, "\n")
    find_in_lines(lines, 0, false, [])
  end

  defp find_in_lines([], _idx, _in_fence, _acc), do: {:not_found, Enum.join([], "\n")}

  defp find_in_lines([line | rest], idx, in_fence, acc) do
    {in_fence, line} = toggle_fence(in_fence, line)

    cond do
      # Closing boundary: standalone `---` when not in a code fence
      !in_fence and String.trim(line) == "---" ->
        frontmatter_text = acc |> Enum.reverse() |> Enum.join("\n")

        body =
          case rest do
            [] -> ""
            _ -> Enum.join(rest, "\n")
          end

        {:found, frontmatter_text, body}

      true ->
        find_in_lines(rest, idx + 1, in_fence, [line | acc])
    end
  end

  # Toggle code-fence state when we encounter ``` lines.
  # Handles both indented and non-indented fences with optional language tags.
  defp toggle_fence(currently_in_fence, line) do
    trimmed = String.trim(line)

    if String.starts_with?(trimmed, "```") do
      {!currently_in_fence, line}
    else
      {currently_in_fence, line}
    end
  end

  # Parse the extracted frontmatter text as YAML.
  defp parse_frontmatter(frontmatter_text, body) do
    case YamlElixir.read_from_string(frontmatter_text) do
      {:ok, frontmatter} when is_map(frontmatter) ->
        {:ok, frontmatter, body}

      {:ok, _} ->
        {:error, "Frontmatter is not a YAML mapping (expected key: value pairs)"}

      {:error, reason} ->
        {:error, "YAML parse error in frontmatter: #{inspect(reason)}"}
    end
  end

  @doc """
  Serializes frontmatter keys and a Markdown body into the `---\\n...\\n---\\n\\n<body>` format.

  Keys with nil values are excluded from the output.
  """
  @spec serialize(map(), String.t()) :: String.t()
  def serialize(frontmatter, body) do
    yaml = encode_frontmatter(frontmatter)
    "---\n#{yaml}\n---\n\n#{body}"
  end

  defp encode_frontmatter(map) when map == %{}, do: ""

  defp encode_frontmatter(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.map(fn {key, value} -> encode_line(key, value) end)
    |> Enum.join("\n")
  end

  defp encode_line(key, value) when is_list(value) do
    key = encode_key(key)

    if value == [] do
      "#{key}: []"
    else
      items = Enum.map_join(value, "\n", fn item -> "  - #{encode_scalar(item)}" end)
      "#{key}:\n#{items}"
    end
  end

  defp encode_line(key, value) when is_map(value) do
    key = encode_key(key)

    nested =
      value
      |> Enum.map(fn {nested_key, nested_value} ->
        "  #{encode_key(nested_key)}: #{encode_scalar(nested_value)}"
      end)
      |> Enum.join("\n")

    "#{key}:\n#{nested}"
  end

  defp encode_line(key, value) when is_integer(value) do
    "#{encode_key(key)}: #{value}"
  end

  defp encode_line(key, value) do
    "#{encode_key(key)}: #{encode_scalar(value)}"
  end

  defp encode_key(key) when is_binary(key), do: Jason.encode!(key)
  defp encode_key(key), do: to_string(key)

  defp encode_scalar(value) when is_binary(value), do: Jason.encode!(value)
  defp encode_scalar(nil), do: "null"
  defp encode_scalar(value), do: to_string(value)
end
