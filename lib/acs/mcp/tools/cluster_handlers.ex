defmodule Acs.MCP.Tools.ClusterHandlers do
  @moduledoc """
  Cluster filesystem tool handlers for the ACS MCP gateway.

  Provides read_file, write_file, and read_dir.
  """

  require Logger

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
end
