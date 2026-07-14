defmodule Acs.Memory.Loader do
  @moduledoc """
  Loads and validates memory files from the canonical store.

  Supports YAML (.yaml) and Markdown+frontmatter (.md) formats.
  Write format is governed by the MEMORY_STORE env var.
  Supports Obsidian vaults via OBSIDIAN_VAULT_PATH.

  Abstracts the filesystem representation of the memory store.
  All memory operations go through the Loader to validate
  before writing to files.
  """

  require Logger

  @doc """
  Returns the full path to the memory directory.

  If OBSIDIAN_VAULT_PATH is set, uses that (supports Obsidian vault
  synced via Syncthing/git/NAS/bind-mount). Otherwise falls back to
  the built-in priv/acs_memory/ directory inside the app.
  """
  def memory_dir do
    obsidian_path = Application.get_env(:steward_acs, :obsidian_vault_path)

    if is_binary(obsidian_path) and obsidian_path != "" do
      Path.join(obsidian_path, "private/memories")
    else
      Path.join(Application.app_dir(:steward_acs), "priv/acs_memory")
    end
  end

  @doc """
  Lists all memory files in the store, optionally filtered by scope.
  Supports .yaml, .yml, and .md extensions.
  Returns a list of file paths.
  """
  def list_files(scope_path \\ nil) do
    pattern = Path.join(memory_dir(), "**/*.{yaml,yml,md}")

    files =
      pattern
      |> Path.wildcard()
      |> Enum.filter(&memory_file?/1)
      |> Enum.filter(&relevant_file?/1)

    case scope_path do
      nil ->
        files

      scope ->
        scope_dir = Path.join(memory_dir(), scope)

        Enum.filter(files, fn f ->
          String.starts_with?(f, scope_dir)
        end)
    end
  end

  # Accept .yaml, .YAML, .yml, .YML, .md, .MD extensions.
  defp memory_file?(path) do
    ext = path |> Path.extname() |> String.downcase()
    ext in [".yaml", ".yml", ".md"]
  end

  # Exclude build artifact copies of test fixtures, not intentional test paths.
  defp relevant_file?(file_path) do
    not String.contains?(file_path, "deps/") and
      not String.contains?(file_path, "/quarantine/") and
      not String.contains?(file_path, "/.obsidian/") and
      not String.starts_with?(file_path, Path.join(memory_dir(), "specs/")) and
      not (String.contains?(file_path, "_build/") and String.contains?(file_path, "/test_app/"))
  end

  @doc """
  Loads a single memory file (YAML or Markdown+frontmatter) and returns
  {:ok, %Acs.Memory{}} or {:error, reason}.
  """
  def load_file(file_path) do
    ext = file_path |> Path.extname() |> String.downcase()

    case ext do
      ".md" -> load_markdown_file(file_path)
      _ -> load_yaml_file(file_path)
    end
  rescue
    e ->
      {:error, "Failed to load #{file_path}: #{inspect(e)}"}
  end

  # Parse a .md file: split frontmatter from body, then validate.
  defp load_markdown_file(file_path) do
    case File.read(file_path) do
      {:ok, content} ->
        case Acs.Memory.Frontmatter.split(content) do
          {:ok, frontmatter, body} ->
            memory_map = Map.put(frontmatter, "content", body)
            validate_and_build(memory_map, file_path)

          {:error, reason} ->
            {:error, "Frontmatter parse error in #{file_path}: #{reason}"}
        end

      {:error, reason} ->
        {:error, "Cannot read #{file_path}: #{inspect(reason)}"}
    end
  end

  # Parse a .yaml/.yml file: pure YAML.
  defp load_yaml_file(file_path) do
    case YamlElixir.read_from_file(file_path) do
      {:ok, memory_map} when is_map(memory_map) ->
        validate_and_build(memory_map, file_path)

      {:ok, _} ->
        {:error, "Invalid structure in #{file_path}: expected a map"}

      {:error, reason} ->
        {:error, "Parse error in #{file_path}: #{inspect(reason)}"}
    end
  end

  defp validate_and_build(memory_map, file_path) do
    memory_map = enforce_path_org(memory_map, file_path)

    case Acs.Memory.validate(memory_map) do
      :ok ->
        memory = Acs.Memory.new(memory_map)
        {:ok, memory}

      {:error, reasons} ->
        {:error, "Validation failed for #{file_path}: #{Enum.join(reasons, "; ")}"}
    end
  end

  defp enforce_path_org(memory_map, file_path) do
    relative = Path.relative_to(file_path, memory_dir())

    case Path.split(relative) do
      ["orgs", path_org | _] ->
        case Map.get(memory_map, "org") do
          nil -> Map.put(memory_map, "org", path_org)
          ^path_org -> memory_map
          other -> raise ArgumentError, "memory org #{inspect(other)} does not match path org"
        end

      _ ->
        # The legacy root layout belongs only to the configured single-tenant
        # instance. Refuse to re-attribute files to another request org.
        Map.put(memory_map, "org", Acs.Org.configured())
    end
  end

  @doc """
  Loads all valid memory files. Returns {:ok, memories, quarantined}
  where memories is a list of valid Acs.Memory structs and quarantined
  is a list of {:quarantine, path, reason} tuples for files that
  could not be loaded.

  This function is a pure reader — it never mutates files on disk.
  Use `quarantine_invalid/0` to write parse_error status to files
  that are valid YAML but fail field validation.
  """
  def load_all do
    files = list_files()

    # Parse each file exactly once — avoids the triple-read bug
    results =
      Enum.map(files, fn file_path ->
        case load_file(file_path) do
          {:ok, memory} -> {:valid, memory}
          {:error, reason} -> {:invalid, file_path, reason}
        end
      end)

    memories =
      Enum.flat_map(results, fn
        {:valid, m} -> [m]
        _ -> []
      end)

    quarantined_info =
      Enum.flat_map(results, fn
        {:valid, _} -> []
        {:invalid, f, reason} -> [{:quarantine, f, reason}]
      end)

    {:ok, memories, quarantined_info}
  end

  @doc """
  Reads all memory files, then writes `status: parse_error` to any
  file that failed validation but contained valid YAML. Files with
  truly malformed YAML are left untouched (they cannot be read or
  written).

  Files that failed validation solely due to an invalid status field
  may be loadable as valid memories (with `parse_error` status) on the
  next `load_all/0` call, allowing the UI to display their contents.
  Files with other validation errors (missing id, title, scope_path,
  invalid kind, etc.) will continue to be quarantined — but their
  YAML is updated with `status: parse_error` for visibility.
  """
  def quarantine_invalid do
    {:ok, _memories, quarantined} = load_all()

    Enum.each(quarantined, fn {:quarantine, file_path, _reason} ->
      case quarantine_file(file_path) do
        :ok ->
          Logger.info("[Memory.Loader] Quarantined #{file_path}")

        {:error, _err} ->
          # quarantine_file already logs; nothing more to do
          :ok
      end
    end)

    :ok
  end

  @doc """
  Writes a parse_error status to a memory YAML file that failed validation.

  For truly malformed YAML that cannot be parsed, the file is moved to a
  'quarantine' subdirectory rather than deleted, preserving the data for
  later inspection.
  """
  def quarantine_file(file_path) do
    # Guard: if file doesn't exist or isn't readable, skip gracefully
    # (load_file already put it in quarantined list because it couldn't parse it,
    # but there's nothing to quarantine since we can't read it either)
    case File.read(file_path) do
      {:error, reason} ->
        Logger.warning(
          "[Memory.Loader] Cannot quarantine unreadable file #{file_path}: #{inspect(reason)}"
        )

        :ok

      {:ok, _} ->
        do_quarantine_file(file_path)
    end
  rescue
    e ->
      {:error, "Failed to quarantine #{file_path}: #{inspect(e)}"}
  end

  # Separated to allow early exit from the inner case without affecting the outer rescue
  defp do_quarantine_file(file_path) do
    # Guard: if the file no longer exists, skip gracefully.
    if File.exists?(file_path) do
      do_quarantine_existing_file(file_path)
    else
      Logger.debug("[Memory.Loader] File vanished before quarantine: #{file_path}")
      :ok
    end
  end

  defp do_quarantine_existing_file(file_path) do
    ext = file_path |> Path.extname() |> String.downcase()

    case ext do
      ".md" -> quarantine_markdown_file(file_path)
      _ -> quarantine_yaml_file(file_path)
    end
  end

  defp quarantine_markdown_file(file_path) do
    case File.read(file_path) do
      {:ok, content} ->
        case Acs.Memory.Frontmatter.split(content) do
          {:ok, frontmatter, body} ->
            if Map.get(frontmatter, "status") == "parse_error" do
              Logger.warning(
                "[Memory.Loader] Skipping quarantine for #{file_path} — already has parse_error status"
              )

              :ok
            else
              updated = Map.put(frontmatter, "status", "parse_error")
              markdown = Acs.Memory.Frontmatter.serialize(updated, body)
              File.write!(file_path, markdown)
              Logger.warning("[Memory.Loader] Quarantined #{file_path} with parse_error status")
              :ok
            end

          {:error, reason} ->
            quarantine_malformed_file(file_path, reason)
            {:error, "Cannot quarantine malformed frontmatter: #{file_path}"}
        end

      {:error, reason} ->
        Logger.warning(
          "[Memory.Loader] Cannot quarantine unreadable file #{file_path}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp quarantine_yaml_file(file_path) do
    case YamlElixir.read_from_file(file_path) do
      {:ok, memory_map} when is_map(memory_map) ->
        if Map.get(memory_map, "status") == "parse_error" do
          Logger.warning(
            "[Memory.Loader] Skipping quarantine for #{file_path} — already has parse_error status"
          )

          :ok
        else
          updated_map = Map.put(memory_map, "status", "parse_error")
          write_yaml_file(file_path, updated_map)
          Logger.warning("[Memory.Loader] Quarantined #{file_path} with parse_error status")
          :ok
        end

      {:ok, _} ->
        {:error, "Cannot quarantine: file does not contain a valid memory map"}

      {:error, reason} ->
        quarantine_malformed_file(file_path, reason)
        {:error, "Cannot quarantine malformed YAML: #{file_path}"}
    end
  end

  @doc """
  Saves a Memory struct to a file in the appropriate location.

  Write format is governed by MEMORY_STORE env var:
  - "obsidian" → Markdown with YAML frontmatter (.md)
  - default ("yaml") → pure YAML (.yaml) — legacy behaviour
  """
  def save(%Acs.Memory{} = memory) do
    file_path = memory_to_path(memory)

    # Ensure directory exists
    Path.dirname(file_path) |> File.mkdir_p!()

    ext = Path.extname(file_path)
    yaml_map = Acs.Memory.to_yaml_map(memory)

    result =
      if String.downcase(ext) == ".md" do
        # Obsidian mode: write frontmatter + content body as markdown
        content = Map.get(yaml_map, "content", "") || ""
        frontmatter = Map.delete(yaml_map, "content")
        markdown = Acs.Memory.Frontmatter.serialize(frontmatter, content)
        write_file_atomically(file_path, markdown)
      else
        write_yaml_file(file_path, yaml_map)
      end

    case result do
      :ok ->
        Logger.info("[Memory.Loader] Saved memory: #{memory.id} -> #{file_path}")
        :ok

      {:error, reason} ->
        {:error, "Failed to save memory: #{inspect(reason)}"}
    end
  rescue
    e ->
      {:error, "Failed to save memory: #{inspect(e)}"}
  end

  defp write_file_atomically(file_path, content) do
    tmp_path = file_path <> ".tmp"

    try do
      File.write!(tmp_path, content)
      File.rename!(tmp_path, file_path)
      :ok
    rescue
      e ->
        _ = File.rm(tmp_path)
        {:error, inspect(e)}
    end
  end

  # Move a malformed YAML file to a quarantine subdirectory instead of deleting.
  # This preserves the data for later inspection while preventing repeated errors.
  defp quarantine_malformed_file(file_path, reason) do
    # Guard: if the file no longer exists (e.g. already moved by a previous
    # quarantine attempt), log debug and return :ok gracefully.
    if File.exists?(file_path) do
      do_quarantine_file(file_path, reason)
    else
      Logger.debug("[Memory.Loader] File already gone, skipping quarantine: #{file_path}")

      :ok
    end
  end

  defp do_quarantine_file(file_path, reason) do
    quarantine_dir = Path.join(memory_dir(), "quarantine")
    File.mkdir_p!(quarantine_dir)

    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    relative_path = Path.relative_to(file_path, memory_dir())
    flat_name = String.replace(relative_path, "/", "__")
    # Strip both .yaml and .md suffixes for the flattened name
    flat_name = String.replace_suffix(flat_name, ".yaml", "")
    flat_name = String.replace_suffix(flat_name, ".yml", "")
    flat_name = String.replace_suffix(flat_name, ".md", "")
    quarantine_name = "#{flat_name}_#{timestamp}.yaml"
    quarantine_path = Path.join(quarantine_dir, quarantine_name)

    case File.rename(file_path, quarantine_path) do
      :ok ->
        Logger.warning(
          "[Memory.Loader] Moved malformed YAML to quarantine: #{quarantine_path} (reason: #{inspect(reason)})"
        )

      {:error, :enametoolong} ->
        # Path is too long — delete the file directly to break the cycle
        Logger.error(
          "[Memory.Loader] Cannot quarantine #{file_path} — path too long (:enametoolong). Deleting to break infinite nesting cycle."
        )

        File.rm(file_path)

      {:error, _rename_err} ->
        # If rename fails, try to copy then delete
        case File.copy(file_path, quarantine_path) do
          {:ok, _} ->
            File.rm(file_path)

            Logger.warning(
              "[Memory.Loader] Copied malformed YAML to quarantine then deleted original: #{quarantine_path}"
            )

          {:error, :enametoolong} ->
            Logger.error(
              "[Memory.Loader] Cannot quarantine #{file_path} — path too long (:enametoolong). Deleting to break infinite nesting cycle."
            )

            File.rm(file_path)

          {:error, copy_err} ->
            Logger.error(
              "[Memory.Loader] Cannot quarantine malformed YAML #{file_path}: #{inspect(reason)}. Move/copy also failed: #{inspect(copy_err)}"
            )
        end
    end
  end

  # Simple YAML serializer for memory data structures.
  # YamlElixir 2.12+ removed encode support, so we write YAML manually.
  defp write_yaml_file(file_path, data) when is_map(data) do
    lines = encode_map(data, 0)
    content = Enum.join(lines, "\n") <> "\n"
    tmp_path = file_path <> ".tmp"

    try do
      File.write!(tmp_path, content)
      File.rename!(tmp_path, file_path)
    rescue
      e ->
        _ = File.rm(tmp_path)
        reraise e, __STACKTRACE__
    end
  end

  defp encode_map(map, indent) do
    Enum.flat_map(map, fn {key, value} ->
      prefix = String.duplicate("  ", indent)

      case value do
        nil ->
          ["#{prefix}#{key}:"]

        %{} = nested ->
          ["#{prefix}#{key}:"] ++ encode_map(nested, indent + 1)

        list when is_list(list) ->
          if list == [] do
            ["#{prefix}#{key}: []"]
          else
            ["#{prefix}#{key}:"] ++
              Enum.map(list, fn item ->
                "  #{prefix}- #{encode_scalar(item)}"
              end)
          end

        _ ->
          ["#{prefix}#{key}: #{encode_scalar(value)}"]
      end
    end)
  end

  defp encode_scalar(value) when is_binary(value) do
    cond do
      # Multiline content: use literal block scalar
      String.contains?(value, "\n") ->
        lines =
          value |> String.split("\n") |> Enum.map(fn line -> "  #{line}" end) |> Enum.join("\n")

        "|\n" <> lines

      # YAML booleans and nulls that could be misinterpreted
      value in ~w(true false yes no on off null ~) ->
        escaped = String.replace(value, "\"", "\\\"")
        ~s("#{escaped}")

      # Values with colons or pipes need quoting
      String.contains?(value, ":") or String.contains?(value, "|") ->
        escaped = String.replace(value, "\"", "\\\"")
        ~s("#{escaped}")

      # Values starting with YAML special characters
      String.starts_with?(value, [
        "'",
        "\"",
        "#",
        "-",
        "?",
        "!",
        "&",
        "*",
        "%",
        "@",
        " ",
        ">",
        "`",
        "[",
        "]",
        "{",
        "}"
      ]) ->
        escaped = String.replace(value, "\"", "\\\"")
        ~s("#{escaped}")

      # Purely numeric values (could be misinterpreted as numbers)
      String.match?(value, ~r/^\d+(\.\d+)?$/) ->
        escaped = String.replace(value, "\"", "\\\"")
        ~s("#{escaped}")

      # Values with leading or trailing whitespace
      value != String.trim(value) ->
        escaped = String.replace(value, "\"", "\\\"")
        ~s("#{escaped}")

      true ->
        value
    end
  end

  defp encode_scalar(value), do: to_string(value)

  @doc """
  Deletes a memory file. Returns :ok or {:error, reason}.
  """
  def delete(%Acs.Memory{} = memory) do
    file_path = memory_to_path(memory)

    case File.rm(file_path) do
      :ok ->
        Logger.info("[Memory.Loader] Deleted memory: #{memory.id}")
        :ok

      {:error, reason} ->
        {:error, "Failed to delete memory file: #{inspect(reason)}"}
    end
  end

  @doc """
  Converts a Memory struct to its expected file path based on scope_path and id.

  Extension is determined by the active MEMORY_STORE config:
  - "obsidian" → .md
  - default ("yaml") → .yaml

  For map input, `scope_path` and `id` are required.
  """
  def memory_to_path(%Acs.Memory{} = memory) do
    ext = store_extension()

    scoped_memory_path(
      memory.org || Acs.Org.current(),
      memory.scope_path,
      memory.id,
      ext
    )
  end

  def memory_to_path(attrs) when is_map(attrs) do
    scope_path = Map.get(attrs, "scope_path", "unknown")
    id = Map.get(attrs, "id", "unknown")
    org = Map.get(attrs, "org") || Acs.Org.current()
    ext = store_extension()
    scoped_memory_path(org, scope_path, id, ext)
  end

  defp scoped_memory_path(org, scope_path, id, ext)
       when org == "default" or org == nil do
    # Preserve the legacy single-tenant layout for existing installations.
    Path.join([memory_dir(), safe_scope_path(scope_path), safe_id(id) <> ext])
  end

  defp scoped_memory_path(org, scope_path, id, ext) do
    Path.join([
      memory_dir(),
      "orgs",
      safe_org(org),
      safe_scope_path(scope_path),
      safe_id(id) <> ext
    ])
  end

  defp safe_id(id) when is_binary(id) and id != "" do
    if Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\z/, id) and not String.contains?(id, "..") do
      id
    else
      raise ArgumentError, "invalid memory id: #{inspect(id)}"
    end
  end

  defp safe_id(id), do: raise(ArgumentError, "invalid memory id: #{inspect(id)}")

  defp safe_org(org) when is_binary(org) and org != "" do
    if Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]*\z/, org) do
      org
    else
      raise ArgumentError, "invalid org: #{inspect(org)}"
    end
  end

  defp safe_org(org), do: raise(ArgumentError, "invalid org: #{inspect(org)}")

  defp safe_scope_path(scope_path) when is_binary(scope_path) do
    if String.contains?(scope_path, "..") or String.starts_with?(scope_path, "/") do
      raise ArgumentError, "invalid scope_path: #{inspect(scope_path)}"
    else
      scope_path
    end
  end

  defp store_extension do
    case Application.get_env(:steward_acs, :memory_store, "yaml") do
      "obsidian" -> ".md"
      _ -> ".yaml"
    end
  end

  @doc """
  Ensures the memory directory structure exists.
  """
  def ensure_directories! do
    File.mkdir_p!(memory_dir())
    :ok
  end
end
