defmodule Acs.Cognition.Loader do
  @moduledoc """
  File I/O for cognition spec YAML files.

  Specs are stored as YAML files in `<specs_root>/<app>/<path>.yaml` where:
  - `<app>` is the application name (e.g., "anantha", "my_app")
  - `<path>` is the underscored module path (e.g., "engine/orchestrator")

  Malformed YAML files are moved to `<specs_root>/quarantine/` for manual review.
  """

  require Logger

  @doc """
  Resolve the specs root directory.

  Resolution order:
  1. `COGNITION_SPECS_PATH` environment variable
  2. Application config `:steward_acs, Acs.Cognition.Loader, :specs_path`
  3. Default: `../../../acs/specs` relative to ACS app dir
  """
  def specs_path do
    System.get_env("COGNITION_SPECS_PATH") ||
      (Application.get_env(:steward_acs, Acs.Cognition.Loader, [])
       |> Keyword.get(:specs_path)) ||
      default_specs_path()
  end

  defp default_specs_path do
    Path.expand("../../../acs/specs", Application.app_dir(:steward_acs))
  end

  @doc """
  Convert a module atom to a spec path string.

  ## Examples
      iex> Acs.Cognition.Loader.module_to_path(Anantha.Engine.Orchestrator)
      "anantha/engine/orchestrator"
  """
  def module_to_path(module) when is_atom(module) do
    module |> Module.split() |> Enum.map(&Macro.underscore/1) |> Enum.join("/")
  end

  @doc """
  Get the full file path for a spec given app and module path.
  """
  def file_path(app, path, ext \\ ".yaml") do
    app = validate_path_segment!(app)
    path = validate_path_segment!(path)
    Path.join([specs_path(), app, "#{path}#{ext}"])
  end

  defp validate_path_segment!(segment) do
    if String.starts_with?(segment, "/") or
       String.contains?(segment, "..") or
       String.match?(segment, ~r/[^a-z0-9_\/\-\.]/) do
      raise ArgumentError, "Invalid path segment: #{inspect(segment)}"
    end

    segment
  end

  @doc """
  List all spec files, optionally filtered by app.
  Returns list of `%{app, path, file_path, relative_path}`.
  """
  def list(opts \\ []) do
    app = opts[:app]
    base = specs_path()

    results =
      cond do
        app && app != "" ->
          dir = Path.join(base, app)
          list_in_dir(dir, app)

        true ->
          apps_dir(base)
          |> Enum.flat_map(fn {sub_app, dir} -> list_in_dir(dir, sub_app) end)
      end

    {:ok, results}
  end

  @doc """
  Load a spec by app and module path. Returns `{:ok, %Entry{}}` or `{:error, reason}`.
  """
  def load(app, path) do
    file = file_path(app, path)

    case File.exists?(file) do
      true -> load_file(file)
      false -> {:error, :not_found}
    end
  end

  @doc """
  Load a spec from a specific file path. Returns `{:ok, %Entry{}}` or `{:error, reason}`.
  """
  def load_file(file_path) do
    ext = Path.extname(file_path) |> String.downcase()

    case ext do
      ".md" -> load_markdown_file(file_path)
      _ -> load_yaml_file(file_path)
    end
  rescue
    e in [FunctionClauseError] ->
      {:error, :load_error, "Invalid spec content: #{Exception.message(e)}"}
  end

  defp load_markdown_file(file_path) do
    case Acs.Memory.Frontmatter.split(file_path) do
      {:ok, frontmatter, body} ->
        map = Map.put(frontmatter, "content", body)
        entry = Acs.Cognition.Entry.from_map(map)
        {:ok, entry}

      {:error, reason} ->
        quarantine_file(file_path, "Frontmatter parse error: #{reason}")
        {:error, :parse_error, reason}
    end
  end

  defp load_yaml_file(file_path) do
    case YamlElixir.read_from_file(file_path) do
      {:ok, map} when is_map(map) ->
        entry = Acs.Cognition.Entry.from_map(map)
        {:ok, entry}

      {:ok, _} ->
        quarantine_file(file_path, "Invalid YAML structure: expected a map")
        {:error, :invalid_yaml}

      {:error, reason} ->
        {:error, :parse_error, reason}
    end
  end

  @doc """
  Save a spec entry to its YAML file. Creates directories as needed.
  Returns `:ok` or `{:error, reason}`.
  """
  def save(%Acs.Cognition.Entry{} = entry) do
    ext = if entry.document_type && Application.get_env(:steward_acs, :memory_store) == "obsidian",
      do: ".md", else: ".yaml"
    file = file_path(entry.app, entry.id, ext)
    File.mkdir_p!(Path.dirname(file))

    case Acs.Cognition.Entry.validate(entry) do
      :ok ->
        content = to_file_content(entry, ext)
        File.write!(file, content)
        Logger.info("Saved cognition entry: #{file}")
        :ok

      {:error, reasons} ->
        {:error, "Validation failed: #{Enum.join(reasons, "; ")}"}
    end
  rescue
    e -> {:error, "Write failed: #{Exception.message(e)}"}
  end

  defp to_file_content(entry, ".md") do
    map = Acs.Cognition.Entry.to_map(entry)
    body = Map.get(map, "content", "") || ""
    frontmatter = Map.drop(map, ["content"])
    Acs.Memory.Frontmatter.serialize(frontmatter, body)
  end

  defp to_file_content(entry, _ext) do
    map = Acs.Cognition.Entry.to_map(entry)
    encode_yaml(map)
  end

  @doc """
  Delete a spec file. Returns `:ok` or `{:error, reason}`.
  """
  def delete(app, path) do
    file = file_path(app, path)

    case File.exists?(file) do
      true ->
        File.rm!(file)
        Logger.info("Deleted cognition spec: #{file}")
        :ok

      false ->
        {:error, :not_found}
    end
  end

  @doc """
  Load all spec entries, optionally filtered by app.
  Returns {:ok, [%Entry{}]}.
  """
  def load_all(opts \\ []) do
    with {:ok, specs} <- list(opts) do
      entries =
        specs
        |> Enum.reduce([], fn spec, acc ->
          case load_file(spec.file_path) do
            {:ok, entry} -> [entry | acc]
            _ -> acc
          end
        end)
        |> Enum.reverse()

      {:ok, entries}
    end
  end

  @doc """
  Find modules without specs in a given lib directory.

  Walks `lib_dir` recursively for `.ex` files, extracts module names from file paths,
  and checks if a corresponding spec exists.

  Returns list of modules that have no spec, as `%{module, path, file_path}`.

  ## Options
    - `app` - Filter to a specific app's specs
    - `existing_specs` - Pre-loaded list of existing specs (avoids scanning specs dir each time)
  """
  def find_undocumented(lib_dir, opts \\ []) do
    app_filter = opts[:app]
    existing = opts[:existing_specs] || list_spec_map(app_filter)

    lib_dir
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.filter(&relevant_module?/1)
    |> Enum.map(&file_to_module_path/1)
    |> Enum.reject(fn {_module, path} ->
      has_spec?(path, existing, app_filter)
    end)
    |> Enum.map(fn {module, path} ->
      # Find which app this module belongs to (by lib_dir path)
      source_app = detect_app(path, lib_dir)
      %{module: module, path: path, app: source_app}
    end)
  end

  # Build a set of existing spec keys: {app, path}
  defp list_spec_map(app_filter) do
    case list(app: app_filter) do
      {:ok, specs} ->
        MapSet.new(specs, fn s -> {s.app, s.path} end)
    end
  end

  # Filter out test files, _build, deps, etc.
  defp relevant_module?(file_path) do
    not (String.contains?(file_path, "_build/") or
           String.contains?(file_path, "deps/") or
           String.contains?(file_path, "/test/"))
  end

  # Convert a .ex file path to module name + spec path
  defp file_to_module_path(file_path) do
    # Extract the path relative to lib/ and strip .ex
    parts = file_path |> Path.rootname() |> Path.split()

    # Find where "lib" appears in the path
    lib_idx = Enum.find_index(parts, &(&1 == "lib"))

    if lib_idx do
      mod_parts = Enum.drop(parts, lib_idx + 1)
      module_name = Enum.map(mod_parts, &Macro.camelize/1) |> Enum.join(".")
      path = Enum.map(mod_parts, &Macro.underscore/1) |> Enum.join("/")
      {module_name, path}
    else
      {Path.basename(file_path, ".ex"), Path.basename(file_path, ".ex") |> Macro.underscore()}
    end
  end

  defp has_spec?(path, existing_specs, nil) do
    Enum.any?(existing_specs, fn {_app, spec_path} -> spec_path == path end)
  end

  defp has_spec?(path, existing_specs, app) do
    MapSet.member?(existing_specs, {app, path})
  end

  defp detect_app(_path, lib_dir) do
    # App name is parent directory name of lib/
    # e.g., /lib -> steward_acs
    lib_dir
    |> Path.dirname()
    |> Path.basename()
  end

  # List .yaml and .yml files in a directory recursively
  defp list_in_dir(dir, app) do
    yaml_pattern = Path.join(dir, "**/*.yaml")
    yml_pattern = Path.join(dir, "**/*.yml")
    md_pattern = Path.join(dir, "**/*.md")

    (Path.wildcard(yaml_pattern) ++ Path.wildcard(yml_pattern) ++ Path.wildcard(md_pattern))
    |> Enum.map(fn file ->
      relative = Path.relative_to(file, Path.join(specs_path(), app))
      ext = Path.extname(relative)
      path = relative |> String.replace_suffix(ext, "")
      %{app: app, path: path, file_path: file, relative_path: relative, ext: ext}
    end)
  end

  defp apps_dir(base) do
    case File.ls(base) do
      {:ok, entries} ->
        entries
        |> Enum.map(fn name -> {name, Path.join(base, name)} end)
        |> Enum.filter(fn {_name, dir} -> File.dir?(dir) end)
        |> Enum.reject(fn {name, _dir} -> name == "quarantine" end)

      {:error, _} ->
        []
    end
  end

  # Move malformed YAML to quarantine
  defp quarantine_file(file_path, reason) do
    quarantine_dir = Path.join([specs_path(), "quarantine"])

    try do
      File.mkdir_p!(quarantine_dir)
      dest = Path.join(quarantine_dir, Path.basename(file_path))
      File.cp!(file_path, dest)
      File.rm!(file_path)
      Logger.warning("Quarantined malformed spec: #{file_path} -> #{dest} (reason: #{reason})")
    rescue
      e ->
        Logger.error("Failed to quarantine #{file_path}: #{Exception.message(e)}")
    end
  end

  @doc false
  # Encode a map to a YAML string. Handles the subset of YAML needed for
  # cognition spec entries: string keys, string values, lists, nested maps.
  def encode_yaml(data, depth \\ 0) do
    indent = String.duplicate("  ", depth)

    case data do
      map when is_map(map) ->
        Enum.map(map, fn {key, value} ->
          encoded_value = encode_yaml_value(value, depth + 1)
          "#{indent}#{key}:#{encoded_value}"
        end)
        |> Enum.join("\n")

      _ ->
        inspect(data)
    end
  end

  defp encode_yaml_value(nil, _depth), do: " ~\n"

  defp encode_yaml_value(value, depth) when is_binary(value) do
    cond do
      # Multi-line: use block scalar
      String.contains?(value, "\n") ->
        " |\n" <> String.duplicate("  ", depth) <> String.replace(value, "\n", "\n" <> String.duplicate("  ", depth))

      # YAML 1.1 implicit type keywords -> single-quote
      needs_yaml_quoting?(value) ->
        " '#{String.replace(value, "'", "''")}'\n"

      # Contains ': ' (key-value pattern in plain text) -> block scalar to avoid map interpretation
      String.contains?(value, ": ") ->
        " |\n" <> String.duplicate("  ", depth) <> value

      # Contains special YAML chars -> block scalar
      String.contains?(value, "#") or
        String.contains?(value, "'") or String.contains?(value, "\"") or
        String.match?(value, ~r/^[>\|]/) ->
        " |\n" <> String.duplicate("  ", depth) <> value

      # Normal string
      true ->
        " #{value}\n"
    end
  end

  defp encode_yaml_value(value, _depth) when is_integer(value), do: " #{value}\n"
  defp encode_yaml_value(value, _depth) when is_float(value), do: " #{value}\n"
  defp encode_yaml_value(true, _depth), do: " true\n"
  defp encode_yaml_value(false, _depth), do: " false\n"

  defp encode_yaml_value(list, depth) when is_list(list) do
    if list == [] do
      " []\n"
    else
      items =
        Enum.map(list, fn item ->
          case item do
            map when is_map(map) ->
              # Nested map in a list — inline representation
              inner =
                Enum.map(map, fn {k, v} ->
                  "  #{String.duplicate("  ", depth)}#{k}: #{encode_yaml_inline_value(v)}"
                end)
                |> Enum.join("\n")

              "#{String.duplicate("  ", depth)}- \n#{inner}"

            str when is_binary(str) ->
              "#{String.duplicate("  ", depth)}- #{encode_list_item_string(str, depth)}"

            other ->
              "#{String.duplicate("  ", depth)}- #{inspect(other)}"
          end
        end)
        |> Enum.join("\n")

      "\n" <> items <> "\n"
    end
  end

  defp needs_yaml_quoting?(value) do
    String.match?(value, ~r/\A(yes|no|true|false|on|off|null|~)\z/i) or
      String.match?(value, ~r/\A\d+(\.\d+)?\z/)
  end

  # Encodes a string value for use in a YAML list item (after "- ").
  # Uses same logic as encode_yaml_value/2 for strings but adapted:
  #   - No leading space (handled by "- " prefix)
  #   - No trailing newline (join handles line separation)
  #   - Block scalar content indented one level deeper than "-"
  defp encode_list_item_string(value, depth) do
    cond do
      # Multi-line: use block scalar, indent content one level deeper
      String.contains?(value, "\n") ->
        "|\n" <> String.duplicate("  ", depth + 1) <>
          String.replace(value, "\n", "\n" <> String.duplicate("  ", depth + 1))

      # YAML 1.1 implicit type keywords -> single-quote
      needs_yaml_quoting?(value) ->
        "'#{String.replace(value, "'", "''")}'"

      # Contains ': ' (key-value pattern) -> block scalar to avoid map interpretation
      String.contains?(value, ": ") ->
        "|\n" <> String.duplicate("  ", depth + 1) <> value

      # Contains special YAML chars -> block scalar
      String.contains?(value, "#") or
        String.contains?(value, "'") or String.contains?(value, "\"") or
        String.match?(value, ~r/^[>\|]/) ->
        "|\n" <> String.duplicate("  ", depth + 1) <> value

      # Normal string
      true ->
        value
    end
  end

  defp encode_yaml_inline_value(nil), do: "~"
  defp encode_yaml_inline_value(value) when is_binary(value) do
    cond do
      # YAML booleans, nulls, and numerics that could be misinterpreted
      needs_yaml_quoting?(value) ->
        "'#{String.replace(value, "'", "''")}'"

      # Values with ': ' (key-value pattern) that could be misinterpreted
      String.contains?(value, ": ") ->
        "'#{String.replace(value, "'", "''")}'"

      # Values with pipe could be misinterpreted as block scalar
      String.contains?(value, "|") ->
        "'#{String.replace(value, "'", "''")}'"

      # Values starting with YAML special characters
      String.starts_with?(value, ["'", "\"", "#", "-", "?", "!", "&", "*", "%", "@", " ", ">"]) ->
        "'#{String.replace(value, "'", "''")}'"

      # Values with leading or trailing whitespace
      value != String.trim(value) ->
        "'#{String.replace(value, "'", "''")}'"

      true ->
        value
    end
  end
  defp encode_yaml_inline_value(value) when is_integer(value), do: Integer.to_string(value)
  defp encode_yaml_inline_value(value) when is_float(value), do: Float.to_string(value)
  defp encode_yaml_inline_value(true), do: "true"
  defp encode_yaml_inline_value(false), do: "false"
  defp encode_yaml_inline_value(other), do: inspect(other)
end
