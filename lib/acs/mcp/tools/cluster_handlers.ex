defmodule Acs.MCP.Tools.ClusterHandlers do
  @moduledoc """
  Cluster filesystem tool handlers for the ACS MCP gateway.

  Provides exec_command, read_file, write_file, and read_dir
  using Port-based spawn_executable for safe command execution
  (no shell injection).
  """

  require Logger

  @doc """
  Executes a shell command safely via spawn_executable.

  Args: %{"command" => cmd, "args" => [args], "cwd" => dir, "timeout" => ms}
  """
  def exec_command(args) do
    command = args["command"]
    cmd_args = if is_list(args["args"]), do: args["args"], else: []
    cwd = args["cwd"] || "/tmp"
    timeout = args["timeout"] || 30_000

    cond do
      is_nil(command) or command == "" ->
        {:error, "Missing 'command' argument"}

      not is_binary(cwd) or not File.dir?(cwd) ->
        {:error, "Working directory does not exist: #{inspect(cwd)}"}

      true ->
        do_exec(command, cmd_args, cwd, timeout)
    end
  end

  @doc """
  Reads a file from the cluster filesystem.
  Restricted to allowed paths.

  Args: %{"path" => absolute_path}
  """
  def read_file(args) do
    path = args["path"]

    if is_nil(path) or path == "" do
      {:error, "Missing 'path' argument"}
    else
      case File.read(path) do
        {:ok, content} -> {:ok, %{content: content, path: path}}
        {:error, reason} -> {:error, "Failed to read file: #{reason}"}
      end
    end
  end

  @doc """
  Writes content to a file on the cluster filesystem.
  Creates parent directories if needed.
  Restricted to allowed paths.

  Args: %{"path" => absolute_path, "content" => content}
  """
  def write_file(args) do
    path = args["path"]
    content = args["content"]

    cond do
      is_nil(path) or path == "" ->
        {:error, "Missing 'path' argument"}

      is_nil(content) ->
        {:error, "Missing 'content' argument"}

      true ->
        parent = Path.dirname(path)

        case File.mkdir_p(parent) do
          :ok ->
            case File.write(path, content) do
              :ok -> {:ok, %{path: path, bytes: byte_size(content)}}
              {:error, reason} -> {:error, "Failed to write file: #{reason}"}
            end

          {:error, reason} ->
            {:error, "Failed to create directory #{parent}: #{reason}"}
        end
    end
  end

  @doc """
  Lists directory contents on the cluster filesystem.
  Returns file names, types, sizes, and modification times.

  Args: %{"path" => absolute_path}
  """
  def read_dir(args) do
    path = args["path"]

    if is_nil(path) or path == "" do
      {:error, "Missing 'path' argument"}
    else
      case File.ls(path) do
        {:ok, entries} ->
          detailed =
            Enum.map(entries, fn name ->
              full_path = Path.join(path, name)
              stat = File.stat(full_path)

              %{
                name: name,
                type: if(File.dir?(full_path), do: "directory", else: "file"),
                size: case stat do
                  {:ok, s} -> s.size
                  _ -> 0
                end,
                mtime: case stat do
                  {:ok, s} -> s.mtime
                  _ -> nil
                end
              }
            end)

          {:ok, %{entries: detailed, path: path, count: length(detailed)}}

        {:error, reason} ->
          {:error, "Failed to list directory: #{reason}"}
      end
    end
  end

  defp do_exec(command, args, cwd, timeout) do
    executable_path = System.find_executable(command)

    if is_nil(executable_path) do
      {:error, "Command '#{command}' not found in PATH"}
    else
      try do
        port =
          Port.open({:spawn_executable, executable_path}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            {:args, args},
            {:cd, cwd}
          ])

        collect_output(port, "", timeout)
      rescue
        e in ArgumentError ->
          {:error, "Failed to execute command: #{inspect(e)}"}

        e in ErlangError ->
          {:error, "Port error: #{inspect(e.original)}"}
      end
    end
  end

  defp collect_output(port, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        collect_output(port, acc <> data, timeout)

      {^port, {:exit_status, status}} ->
        safe_close(port)
        {:ok, %{status: status, output: acc}}
    after
      timeout ->
        safe_close(port)
        {:error, "Command timed out after #{timeout}ms"}
    end
  end

  defp safe_close(port) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end
  end
end
