defmodule Acs.MCP.ToolLoader do
  @moduledoc """
  Loads and validates MCP tool definitions from YAML files.

  Reads all `.yaml` files from configured directories
  (default: `acs/acstools/` relative to the app root)
  and returns validated tool definitions merged from all files.

  Supports multiple directories via:
  1. `MCP_TOOLS_PATH` environment variable (comma-separated paths)
  2. Application config `:tools_paths` (list of paths) or `:tools_path` (single path, legacy)
  3. Default: `acs/acstools/` relative to app directory
  """

  require Logger

  @doc """
  Returns the configured tools paths from environment and application config.

  Resolution order:
  1. `MCP_TOOLS_PATH` environment variable (comma-separated)
  2. Application config `:steward_acs, Acs.MCP.ToolLoader, :tools_paths` (list)
  3. Application config `:steward_acs, Acs.MCP.ToolLoader, :tools_path` (single, legacy)
  4. Default: `acs/acstools/` relative to app directory

  Only paths that exist on disk are returned.
  """
  def tools_paths do
    env_paths = parse_env_paths(System.get_env("MCP_TOOLS_PATH"))

    config_paths =
      case Application.get_env(:steward_acs, Acs.MCP.ToolLoader) do
        nil -> []
        config ->
          (config[:tools_paths] || [config[:tools_path]] |> List.wrap())
          |> Enum.filter(& &1)
      end

    default = default_tools_path()

    (env_paths ++ config_paths ++ [default])
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.filter(&File.exists?/1)
  end

  defp parse_env_paths(nil), do: []

  defp parse_env_paths(path) do
    path |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end

  defp default_tools_path do
    Path.expand("../../../acs/acstools", Application.app_dir(:steward_acs))
  end

  @doc """
  Loads all tool definitions from YAML files in all configured tools directories.

  Returns `{:ok, tools_by_app}` where tools_by_app is a map of:
  `%{app_name => %{app_info: ..., tools: [tool_def, ...]}}`

  Or `{:ok, %{}}` if no paths are found.
  """
  def load_all do
    paths = tools_paths()

    if paths == [] do
      Logger.warning("No MCP tools paths found")
      {:ok, %{}}
    else
      paths
      |> Enum.reduce({:ok, %{}}, fn path, {:ok, acc} ->
        case load_from_path(path) do
          {:ok, app_configs} -> {:ok, merge_configs(acc, app_configs)}
          {:error, reason} ->
            Logger.warning("Failed to load tools from #{path}: #{reason}")
            {:ok, acc}
        end
      end)
    end
  end

  defp load_from_path(path) do
    path
    |> Path.join("*.yaml")
    |> Path.wildcard()
    |> Enum.reduce({:ok, %{}}, fn file, {:ok, acc} ->
      case load_file(file) do
        {:ok, app_config} ->
          app_name = app_config["app"]
          {:ok, Map.update(acc, app_name, app_config, fn existing ->
            Map.update(existing, "tools", app_config["tools"], fn existing_tools ->
              existing_tools ++ app_config["tools"]
            end)
          end)}

        {:error, reason} ->
          Logger.warning("Failed to load tool file #{file}: #{reason}")
          {:ok, acc}
      end
    end)
  end

  defp merge_configs(acc, new_configs) do
    Map.merge(acc, new_configs, fn _app, existing, new ->
      Map.update(existing, "tools", new["tools"], fn existing_tools ->
        existing_tools ++ new["tools"]
      end)
    end)
  end

  @doc """
  Loads and validates a single YAML tool definition file.
  """
  def load_file(file_path) do
    case YamlElixir.read_from_file(file_path) do
      {:ok, config} when is_map(config) ->
        case validate_config(config) do
          :ok -> {:ok, config}
          {:error, reason} -> {:error, reason}
        end

      {:ok, _} ->
        {:error, "Invalid YAML structure: expected a map at root"}

      {:error, reason} ->
        {:error, "Failed to load #{file_path}: #{inspect(reason)}"}
    end
  end

  @doc """
  Validates a tool configuration map.

  Required top-level fields:
  - `app` (string) - App name
  - `tools` (list) - List of tool definitions

  Each tool definition requires:
  - `name` (string) - Tool name
  - `description` (string) - Tool description
  - Either `handler` (module) or `endpoint` (string) + `method` (string)
  - `params` (list, optional) - Parameter definitions (used to build input_schema)
  - `input_schema` (map, optional) - Direct JSON Schema for input parameters (alternative to `params`)
  - `permissions` (list of strings, optional) - Required agent permissions

  Returns `:ok` or `{:error, reason}`.
  """
  def validate_config(config) do
    cond do
      not is_map_key(config, "app") ->
        {:error, "Missing required field: 'app'"}

      not is_binary(config["app"]) ->
        {:error, "'app' must be a string"}

      not is_map_key(config, "tools") ->
        {:error, "Missing required field: 'tools'"}

      not is_list(config["tools"]) ->
        {:error, "'tools' must be a list"}

      config["tools"] == [] ->
        {:error, "'tools' list cannot be empty"}

      true ->
        # Validate each tool
        errors =
          config["tools"]
          |> Enum.with_index()
          |> Enum.reduce([], fn {tool, idx}, acc ->
            case validate_tool(tool) do
              :ok -> acc
              {:error, reason} -> ["Tool ##{idx + 1} (#{tool["name"] || "unnamed"}): #{reason}" | acc]
            end
          end)
          |> Enum.reverse()

        if errors == [] do
          :ok
        else
          {:error, Enum.join(errors, "; ")}
        end
    end
  end

  defp validate_tool(tool) do
    cond do
      not is_map_key(tool, "name") ->
        {:error, "Missing required field: 'name'"}

      not is_binary(tool["name"]) ->
        {:error, "'name' must be a string"}

      not is_map_key(tool, "description") ->
        {:error, "Tool '#{tool["name"]}' missing 'description'"}

      not is_binary(tool["description"]) ->
        {:error, "Tool '#{tool["name"]}' 'description' must be a string"}

      not has_handler?(tool) and not has_endpoint?(tool) ->
        {:error, "Tool '#{tool["name"]}' must have either 'handler' or 'endpoint' + 'method'"}

      has_endpoint?(tool) and not is_binary(tool["endpoint"]) ->
        {:error, "Tool '#{tool["name"]}' 'endpoint' must be a string"}

      has_endpoint?(tool) and not is_binary(tool["method"]) ->
        {:error, "Tool '#{tool["name"]}' 'method' must be a string"}

      has_endpoint?(tool) and tool["method"] not in ["GET", "POST", "PUT", "DELETE", "PATCH"] ->
        {:error, "Tool '#{tool["name"]}' 'method' must be GET, POST, PUT, DELETE, or PATCH"}

      is_map_key(tool, "category") and not is_binary(tool["category"]) ->
        {:error, "Tool '#{tool["name"]}' 'category' must be a string"}

      is_map_key(tool, "level") and not is_integer(tool["level"]) ->
        {:error, "Tool '#{tool["name"]}' 'level' must be an integer"}

      is_map_key(tool, "roles") and not is_list(tool["roles"]) ->
        {:error, "Tool '#{tool["name"]}' 'roles' must be a list"}

      is_map_key(tool, "roles") and Enum.any?(tool["roles"], fn r -> not is_binary(r) end) ->
        {:error, "Tool '#{tool["name"]}' 'roles' must be a list of strings"}

      is_map_key(tool, "permissions") and not is_list(tool["permissions"]) ->
        {:error, "Tool '#{tool["name"]}' 'permissions' must be a list"}

      is_map_key(tool, "permissions") and Enum.any?(tool["permissions"], fn p -> not is_binary(p) end) ->
        {:error, "Tool '#{tool["name"]}' 'permissions' must be a list of strings"}

      is_map_key(tool, "params") and not is_list(tool["params"]) ->
        {:error, "Tool '#{tool["name"]}' 'params' must be a list"}

      is_map_key(tool, "input_schema") and not is_map(tool["input_schema"]) ->
        {:error, "Tool '#{tool["name"]}' 'input_schema' must be a map"}

      is_map_key(tool, "input_schema") and tool["input_schema"]["type"] != "object" ->
        {:error, "Tool '#{tool["name"]}' 'input_schema.type' must be 'object'"}

      true ->
        # Validate params if present (not needed for input_schema)
        params = tool["params"] || []
        errors = if is_nil(tool["input_schema"]), do: validate_params(tool["name"], params, 0), else: []
        if errors == [], do: :ok, else: {:error, Enum.join(errors, "; ")}
    end
  end

  defp has_handler?(tool), do: is_map_key(tool, "handler") and not is_nil(tool["handler"])
  defp has_endpoint?(tool), do: is_map_key(tool, "endpoint") and not is_nil(tool["endpoint"])

  defp validate_params(_tool_name, [], _idx), do: []

  defp validate_params(tool_name, [param | rest], idx) do
    errors =
      cond do
        not is_map(param) ->
          ["Param ##{idx + 1}: must be a map"]

        not is_map_key(param, "name") ->
          ["Param ##{idx + 1}: missing 'name'"]

        not is_binary(param["name"]) ->
          ["Param '#{param["name"]}': 'name' must be a string"]

        not is_map_key(param, "type") ->
          ["Param '#{param["name"]}': missing 'type'"]

        not is_binary(param["type"]) ->
          ["Param '#{param["name"]}': 'type' must be a string"]

        true ->
          []
      end

    errors ++ validate_params(tool_name, rest, idx + 1)
  end

  @doc """
  Converts a loaded YAML config into the MCP tool definition format.

  For internal tools (with `handler`), the handler module is stored as-is.
  For external tools (with `endpoint`), the base_url and endpoint are stored.

  Returns a list of tool maps ready for MCP protocol.
  """
  def to_mcp_tools(app_config) do
    base_url = app_config["base_url"] || ""
    app_name = app_config["app"]

    Enum.map(app_config["tools"], fn tool ->
      params = tool["params"] || []

      input_schema =
        if is_map(tool["input_schema"]) do
          # Use directly provided JSON Schema input_schema
          tool["input_schema"]
        else
          # Build from params list format
          %{
            "type" => "object",
            "properties" => build_properties(params),
            "required" => build_required(params)
          }
        end

      %{
        "name" => if app_config["prefix"] == false do
          tool["name"]
        else
          "#{app_name}_#{tool["name"]}"
        end,
        "description" => tool["description"],
        "inputSchema" => input_schema,
        "category" => tool["category"] || "uncategorized",
        "level" => tool["level"] || 2,
        "app" => app_name,
        "base_url" => base_url,
        "endpoint" => tool["endpoint"],
        "method" => tool["method"],
        "handler" => tool["handler"],
        "params" => params,
        "permissions" => tool["permissions"],
        "timeout" => tool["timeout"],
        "response_transform" => tool["response_transform"]
      }
    end)
  end

  defp build_properties(params) do
    Map.new(params, fn param ->
      type = param["type"]

      prop =
        case type do
          "array" ->
            %{
              "type" => "array",
              "items" => param["items"] || %{"type" => "string"},
              "description" => param["description"] || ""
            }

          "json" ->
            %{
              "type" => "object",
              "description" => param["description"] || ""
            }

          "boolean" ->
            %{
              "type" => "boolean",
              "description" => param["description"] || ""
            }

          _ ->
            %{
              "type" => type,
              "description" => param["description"] || ""
            }
        end

      {param["name"], prop}
    end)
  end

  defp build_required(params) do
    Enum.filter(params, & &1["required"])
    |> Enum.map(& &1["name"])
  end

end
