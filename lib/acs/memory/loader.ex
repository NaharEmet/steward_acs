defmodule Acs.Memory.Loader do
  @moduledoc """
  Loads and validates YAML memory files from priv/acs_memory/.

  Abstracts the filesystem representation of the memory store.
  All memory operations go through the Loader to validate
  before writing to YAML files.
  """

  require Logger

  @memory_dir "priv/acs_memory"

  @doc """
  Returns the full path to the memory directory.
  """
  def memory_dir do
    Path.join(Application.app_dir(:steward_acs), @memory_dir)
  end

  @doc """
  Lists all memory YAML files in the store, optionally filtered by scope.
  Returns a list of file paths.
  """
  def list_files(scope_path \\ nil) do
    pattern = Path.join(memory_dir(), "**/*.yaml")

    files =
      pattern
      |> Path.wildcard()
      |> Enum.filter(&yaml_file?/1)
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

  # Filter to only include files with a .yaml or .YAML extension.
  # Path.wildcard only matches lowercase .yaml, but this ensures
  # any non-YAML files in the directory are excluded.
  defp yaml_file?(path) do
    ext = Path.extname(path)
    ext == ".yaml" or ext == ".YAML"
  end

  # Exclude files from deps/, quarantine/, and test_app/ directories to prevent:
  # - Picking up YAML files from dependencies
  # - Re-processing files already moved to a quarantine subdirectory
  # - Test lifecycle files from test_app/ that get copied into _build/
  # NOTE: /test/ NOT excluded here because _build/test/ matches and
  # would exclude ALL memory files during test runs.
  defp relevant_file?(file_path) do
    not String.contains?(file_path, "deps/") and
      not String.contains?(file_path, "/quarantine/") and
      not String.contains?(file_path, "/test_app/")
  end

  @doc """
  Loads a single YAML memory file and returns {:ok, %Acs.Memory{}}
  or {:error, reason}.
  """
  def load_file(file_path) do
    case YamlElixir.read_from_file(file_path) do
      {:ok, memory_map} when is_map(memory_map) ->
        case Acs.Memory.validate(memory_map) do
          :ok ->
            memory = Acs.Memory.new(memory_map)
            {:ok, memory}

          {:error, reasons} ->
            {:error, "Validation failed for #{file_path}: #{Enum.join(reasons, "; ")}"}
        end

      {:ok, _} ->
        {:error, "Invalid YAML structure in #{file_path}: expected a map"}

      {:error, reason} ->
        {:error, "YAML parse error in #{file_path}: #{inspect(reason)}"}
    end
  rescue
    e ->
      {:error, "Failed to load #{file_path}: #{inspect(e)}"}
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
    case YamlElixir.read_from_file(file_path) do
      {:ok, memory_map} when is_map(memory_map) ->
        # Guard: if already quarantined, skip the write to avoid infinite loops
        if Map.get(memory_map, "status") == "parse_error" do
          Logger.warning(
            "[Memory.Loader] Skipping quarantine for #{file_path} — already has parse_error status"
          )

          :ok
        else
          # Set the error status
          updated_map = Map.put(memory_map, "status", "parse_error")

          # Write back
          write_yaml_file(file_path, updated_map)
          Logger.warning("[Memory.Loader] Quarantined #{file_path} with parse_error status")
          :ok
        end

      {:ok, _} ->
        {:error, "Cannot quarantine: file does not contain a valid memory map"}

      {:error, reason} ->
        # Truly malformed YAML - can't parse, can't quarantine.
        # Move the file to quarantine subdirectory to prevent repeated errors.
        quarantine_malformed_file(file_path, reason)
        {:error, "Cannot quarantine malformed YAML: #{file_path}"}
    end
  end

  @doc """
  Saves a Memory struct to a YAML file in the appropriate location.
  Returns :ok or {:error, reason}.
  """
  def save(%Acs.Memory{} = memory) do
    file_path = memory_to_path(memory)

    # Ensure directory exists
    Path.dirname(file_path) |> File.mkdir_p!()

    yaml_map = Acs.Memory.to_yaml_map(memory)
    write_yaml_file(file_path, yaml_map)

    Logger.info("[Memory.Loader] Saved memory: #{memory.id} -> #{file_path}")
    :ok
  rescue
    e ->
      {:error, "Failed to save memory: #{inspect(e)}"}
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
    # Use fixed quarantine directory at memory root (like Cognition.Loader does).
    # This prevents deeply nested quarantine/ directories.
    quarantine_dir = Path.join(memory_dir(), "quarantine")
    File.mkdir_p!(quarantine_dir)

    # Generate unique name with timestamp to avoid conflicts.
    # Preserve location context by flattening the relative path into the filename.
    # e.g., "lib/anantha_os/core/claims.ex.yaml" -> "lib__anantha_os__core__claims.ex_TIMESTAMP.yaml"
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    relative_path = Path.relative_to(file_path, memory_dir())
    flat_name = String.replace(relative_path, "/", "__")
    flat_name = String.replace_suffix(flat_name, ".yaml", "")
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

  Each memory gets its own file at `scope_path/id.yaml` to prevent
  multiple memories with the same scope from overwriting each other.

  For map input, `scope_path` and `id` are required.
  """
  def memory_to_path(%Acs.Memory{} = memory) do
    # scope_path: "agent_coordination_system/cache/invalidation"
    # id: "abc123"
    # → path: priv/acs_memory/agent_coordination_system/cache/invalidation/abc123.yaml
    Path.join([memory_dir(), memory.scope_path, memory.id <> ".yaml"])
  end

  def memory_to_path(attrs) when is_map(attrs) do
    scope_path = Map.get(attrs, "scope_path", "unknown")
    id = Map.get(attrs, "id", "unknown")
    Path.join([memory_dir(), scope_path, id <> ".yaml"])
  end

  @doc """
  Ensures the memory directory structure exists.
  """
  def ensure_directories! do
    File.mkdir_p!(memory_dir())
    :ok
  end
end
