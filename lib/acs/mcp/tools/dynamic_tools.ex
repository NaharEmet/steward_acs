defmodule Acs.MCP.Tools.DynamicTools do
  @moduledoc """
  Handles dynamic tool operations: writing new tool definitions to the cluster
  filesystem and hot-reloading them without requiring a BEAM recompile.

  Supports endpoint-based tools (via `Acs.MCP.Bridge`) which don't need
  BEAM compilation - the tool is registered as a YAML definition and dispatched
  via HTTP at runtime.

  ## Operations

  - `write_tool` — Write a new tool definition YAML file, then call
    `Acs.MCP.ToolRegistry.refresh/0` to hot-reload all tools into memory.
  """

  require Logger

  @doc """
  Main entry point for dynamic tool operations.

  Returns `{:ok, result}` on success or `{:error, reason}` on failure.
  """
  def call_tool("write_tool", args) do
    with :ok <- validate_write_tool(args),
         yaml <- build_yaml(args),
         {:ok, path} <- write_tool_file(args, yaml) do
      case Acs.MCP.ToolRegistry.refresh() do
        :ok ->
          {:ok, %{tool: args["name"], path: path, reloaded: true}}

        {:error, reason} ->
          {:error, "Write succeeded but refresh failed: #{reason}"}
      end
    end
  end

  def call_tool(name, _args), do: {:error, "Unknown dynamic tool: #{name}"}

  defp validate_write_tool(args) do
    cond do
      not is_map_key(args, "name") or not is_binary(args["name"]) or args["name"] == "" ->
        {:error, "Missing required field: 'name' must be a non-empty string"}

      not is_map_key(args, "description") or not is_binary(args["description"]) ->
        {:error, "Missing required field: 'description' must be a string"}

      not is_map_key(args, "inputSchema") or not is_map(args["inputSchema"]) ->
        {:error, "Missing required field: 'inputSchema' must be a JSON Schema object"}

      has_no_handler?(args) and has_no_endpoint?(args) ->
        {:error,
         "Must provide either 'handler' (Elixir module name) or 'endpoint' (HTTP URL)"}

      is_map_key(args, "permissions") and not is_list(args["permissions"]) ->
        {:error, "'permissions' must be a list of strings"}

      is_map_key(args, "permissions") and Enum.any?(args["permissions"], fn p -> not is_binary(p) end) ->
        {:error, "'permissions' must be a list of strings"}

      true ->
        :ok
    end
  end

  defp has_no_handler?(args) do
    not is_map_key(args, "handler") or
      args["handler"] in [nil, "", "Acs.MCP.Tools"]
  end

  defp has_no_endpoint?(args) do
    not is_map_key(args, "endpoint") or
      not is_binary(args["endpoint"]) or
      args["endpoint"] == ""
  end

  defp build_yaml(args) do
    tool_name = args["name"]
    app = args["app"] || "custom"

    # Convert MCP camelCase inputSchema to YAML snake_case input_schema
    input_schema = args["inputSchema"]

    tool = %{
      "name" => tool_name,
      "app" => app,
      "description" => args["description"],
      "input_schema" => input_schema,
      "level" => args["level"] || 1,
      "role" => args["role"] || "admin",
      "category" => args["category"] || "custom"
    }

    # Include permissions if provided
    tool = if is_map_key(args, "permissions") and is_list(args["permissions"]) and args["permissions"] != [] do
      Map.put(tool, "permissions", args["permissions"])
    else
      tool
    end

    {tool, base_url} = add_handler_or_endpoint(tool, args)

    # Build the full app config
    config = %{
      "app" => app,
      "base_url" => base_url,
      "prefix" => false,
      "description" => args["description"],
      "tools" => [tool]
    }

    encode_yaml(config)
  end

  # Add handler (Elixir module) or endpoint (HTTP URL + method) to the tool map.
  # Only adds the relevant fields — avoids setting empty keys that would
  # cause ToolLoader validation failures.
  defp add_handler_or_endpoint(tool, args) do
    has_handler =
      is_map_key(args, "handler") and is_binary(args["handler"]) and
        args["handler"] != "" and args["handler"] != "Acs.MCP.Tools"

    has_endpoint =
      is_map_key(args, "endpoint") and is_binary(args["endpoint"]) and args["endpoint"] != ""

    cond do
      has_handler ->
        {Map.put(tool, "handler", args["handler"]), ""}

      has_endpoint ->
        ep = args["endpoint"]
        tool = Map.put(tool, "method", "POST")

        if is_map_key(args, "base_url") and is_binary(args["base_url"]) and
             args["base_url"] != "" do
          {Map.put(tool, "endpoint", ep), args["base_url"]}
        else
          case split_endpoint_url(ep) do
            {:ok, bu, ep_path} ->
              {Map.put(tool, "endpoint", ep_path), bu}

            :error ->
              {Map.put(tool, "endpoint", ep), ""}
          end
        end

      true ->
        # Shouldn't reach here due to validation, but safeguard
        {tool, ""}
    end
  end

  defp write_tool_file(args, yaml_content) do
    tool_name = args["name"]
    dir = tools_write_dir()
    path = Path.join(dir, "#{tool_name}.yaml")

    with :ok <- ensure_dir_exists(dir) do
      if File.exists?(path) do
        case YamlElixir.read_from_file(path) do
          {:ok, existing} when is_map(existing) ->
            new_tool = parse_tool_from_yaml(yaml_content)
            existing_tools = existing["tools"] || []
            updated = Map.put(existing, "tools", existing_tools ++ [new_tool])

            case File.write(path, encode_yaml(updated)) do
              :ok -> {:ok, path}
              {:error, reason} -> {:error, "Failed to write tool file: #{reason}"}
            end

          _ ->
            case File.write(path, yaml_content) do
              :ok -> {:ok, path}
              {:error, reason} -> {:error, "Failed to write tool file: #{reason}"}
            end
        end
      else
        case File.write(path, yaml_content) do
          :ok -> {:ok, path}
          {:error, reason} -> {:error, "Failed to write tool file: #{reason}"}
        end
      end
    end
  end

  defp ensure_dir_exists(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, "Failed to create directory: #{reason}"}
    end
  end

  defp parse_tool_from_yaml(yaml_content) do
    {:ok, config} = YamlElixir.read_from_string(yaml_content)
    tools = config["tools"] || []
    List.first(tools) || %{}
  end

  @doc false
  def split_endpoint_url(url) when is_binary(url) do
    uri = URI.parse(url)

    if uri.scheme in ~w(http https) and is_binary(uri.host) do
      port_str =
        if uri.port && uri.port != URI.default_port(uri.scheme), do: ":#{uri.port}", else: ""

      base_url = "#{uri.scheme}://#{uri.host}#{port_str}"
      endpoint_path = uri.path || "/"
      {:ok, base_url, endpoint_path}
    else
      :error
    end
  end

  defp tools_write_dir do
    path =
      case System.get_env("MCP_TOOLS_PATH") do
        env when is_binary(env) and env != "" ->
          env |> String.split(",", trim: true) |> List.first() |> String.trim()

        _ ->
          configured =
            case Application.get_env(:steward_acs, Acs.MCP.ToolLoader) do
              nil -> []
              config ->
                (config[:tools_paths] || [config[:tools_path]] |> List.wrap())
                |> Enum.filter(& &1)
            end

          case configured do
            [] ->
              Path.expand("../../../acs/acstools",
                Application.app_dir(:steward_acs)
              )

            [first | _] ->
              first
          end
      end

    path
  end

  # Produces block-style YAML matching the format expected by ToolLoader:
  #
  #   app: my_app
  #   base_url: ""
  #   tools:
  #     - name: tool_name
  #       description: "..."
  #       input_schema:
  #         type: object
  #         properties:
  #           key:
  #             type: string
  #       required:
  #         - key
  #

  defp encode_yaml(data) do
    data
    |> encode_nodes(0)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  # Map: each key-value pair on its own line
  defp encode_nodes(value, depth) when is_map(value) do
    Enum.flat_map(value, fn {key, val} ->
      encode_map_entry(key, val, depth)
    end)
  end

  # List: each item prefixed with "- "
  defp encode_nodes(list, depth) when is_list(list) do
    indent = String.duplicate("  ", depth)

    Enum.flat_map(list, fn item ->
      case item do
        %{} = map when map_size(map) > 0 ->
          encode_map_as_list_item(map, depth)

        other ->
          ["#{indent}- #{yaml_scalar(other)}"]
      end
    end)
  end

  defp encode_map_as_list_item(map, depth) do
    indent = String.duplicate("  ", depth)
    next_indent = String.duplicate("  ", depth + 1)

    # Encode all entries at (depth + 1) — "- " replaces 2 spaces
    all_lines =
      Enum.flat_map(Map.to_list(map), fn {k, v} ->
        encode_map_entry(k, v, depth + 1)
      end)

    case all_lines do
      [] ->
        []

      [first | rest] ->
        trimmed = String.trim_leading(first, next_indent)
        ["#{indent}- #{trimmed}" | rest]
    end
  end

  defp encode_map_entry(key, value, depth) do
    indent = String.duplicate("  ", depth)

    cond do
      is_map(value) and map_size(value) > 0 ->
        ["#{indent}#{key}:"] ++ encode_nodes(value, depth + 1)

      is_list(value) and value != [] ->
        ["#{indent}#{key}:"] ++ encode_nodes(value, depth + 1)

      is_list(value) and value == [] ->
        ["#{indent}#{key}: []"]

      is_nil(value) ->
        ["#{indent}#{key}: ~"]

      true ->
        ["#{indent}#{key}:#{yaml_scalar(value)}"]
    end
  end

  defp yaml_scalar(value) when is_binary(value) do
    cond do
      value == "" ->
        " ''"

      needs_quoting?(value) ->
        " #{quote_string(value)}"

      true ->
        " #{value}"
    end
  end

  defp yaml_scalar(value) when is_integer(value), do: " #{value}"
  defp yaml_scalar(value) when is_boolean(value), do: " #{value}"
  defp yaml_scalar(nil), do: " ~"
  defp yaml_scalar(value), do: " #{inspect(value)}"

  defp needs_quoting?(value) do
    String.contains?(value, ": ") or
      String.contains?(value, "#") or
      String.contains?(value, "\"") or
      String.contains?(value, "'") or
      String.starts_with?(value, [" ", "'", "\"", "&", "*", "!", "|", ">", "?", "%", "@"]) or
      String.match?(value, ~r/^(yes|no|true|false|on|off|null|~)$/i) or
      String.match?(value, ~r/^\d+/)
  end

  defp quote_string(value) do
    escaped = String.replace(value, "\"", "\\\"")
    ~s("#{escaped}")
  end
end
