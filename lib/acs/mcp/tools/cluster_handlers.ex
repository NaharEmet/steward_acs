defmodule Acs.MCP.Tools.ClusterHandlers do
  @moduledoc """
  Cluster filesystem tool handlers for the ACS MCP gateway.

  Provides read_file, write_file, and read_dir restricted via `:allowed_paths`
  application config.
  """

  @doc """
  Reads a file from the cluster filesystem.
  Restricted to allowed paths.

  Args: %{"path" => absolute_path}
  """
  def read_file(args) do
    path = args["path"]

    cond do
      is_nil(path) or path == "" ->
        {:error, "Missing required parameter: 'path'"}

      not path_allowed?(path) ->
        {:error, "Path '#{path}' is not in allowed paths"}

      true ->
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
      is_nil(path) or path == "" or is_nil(content) ->
        {:error, "Missing required parameters: 'path' and 'content'"}

      not path_allowed?(path) ->
        {:error, "Path '#{path}' is not in allowed paths"}

      true ->
        parent = Path.dirname(path)

        case File.mkdir_p(parent) do
          :ok ->
            case File.write(path, content) do
              :ok -> {:ok, %{path: path, status: "written", bytes: byte_size(content)}}
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

    cond do
      is_nil(path) or path == "" ->
        {:error, "Missing required parameter: 'path'"}

      not path_allowed?(path) ->
        {:error, "Path '#{path}' is not in allowed paths"}

      true ->
        case File.ls(path) do
          {:ok, entries} ->
            detailed =
              Enum.map(entries, fn name ->
                full_path = Path.join(path, name)
                stat = File.stat(full_path)

                %{
                  name: name,
                  type: if(File.dir?(full_path), do: "directory", else: "file"),
                  size:
                    case stat do
                      {:ok, s} -> s.size
                      _ -> 0
                    end,
                  mtime:
                    case stat do
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

  defp path_allowed?(path) when is_binary(path) do
    case Application.get_env(:steward_acs, :allowed_paths) do
      list when is_list(list) and list != [] ->
        expanded = Path.expand(path)

        resolved =
          if File.exists?(expanded) do
            resolve_symlink_path(expanded)
          else
            expanded
          end

        Enum.any?(list, fn allowed ->
          under_root?(resolved, Path.expand(allowed))
        end)

      _ ->
        false
    end
  end

  defp under_root?(path, root) do
    path == root or String.starts_with?(path, root <> "/")
  end

  defp resolve_symlink_path(path) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} ->
        case File.read_link(path) do
          {:ok, target} -> resolve_symlink_path(Path.expand(target, Path.dirname(path)))
          {:error, _} -> path
        end

      _ ->
        path
    end
  end

  defp path_allowed?(_), do: false
end
