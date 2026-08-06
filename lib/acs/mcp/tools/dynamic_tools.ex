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
    with {:ok, result, rollback} <- persist_tool(args) do
      case Acs.MCP.ToolRegistry.refresh() do
        :ok ->
          {:ok, Map.put(result, :reloaded, true)}

        {:error, reason} ->
          rollback_result = rollback_tool(rollback)
          _ = Acs.MCP.ToolRegistry.refresh()

          case rollback_result do
            :ok ->
              {:error, "Tool validation failed; write rolled back: #{reason}"}

            {:error, rollback_reason} ->
              Logger.error("Tenant tool rollback failed: #{inspect(rollback_reason)}")

              {:error,
               "Tool validation failed and rollback failed: #{reason}; #{inspect(rollback_reason)}"}
          end
      end
    end
  end

  def call_tool(name, _args), do: {:error, "Unknown dynamic tool: #{name}"}

  @doc false
  def persist_tool(args) do
    with {:ok, credential_org} <- credential_org(args),
         :ok <- validate_write_tool(args) do
      config = build_config(args)

      if Acs.Org.multi_tenant?() do
        persist_database_tool(args, config, credential_org)
      else
        yaml = encode_yaml(config)

        with {:ok, path, previous} <- write_tool_file(args, yaml, credential_org) do
          {:ok, %{tool: args["name"], path: path}, {path, previous}}
        end
      end
    end
  end

  @doc false
  def rollback_tool({:database, org, public_id, previous, written_head}) do
    with {:ok, current} <- database_tool_snapshot(org, public_id) do
      snapshot =
        case previous do
          :missing -> Map.put(current.snapshot, "active", false)
          {:existing, snapshot} -> snapshot
        end

      case Acs.Artifacts.Ledger.save(:tool, public_id, snapshot,
             org: org,
             expected_head_revision_id: written_head,
             operation: "restore",
             actor: %{type: "system", id: "tool_refresh_rollback"},
             source: "system",
             message: "Rollback tenant tool #{public_id} after refresh failure"
           ) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def rollback_tool({path, :missing}), do: File.rm(path)

  def rollback_tool({path, {:existing, content}}) do
    atomic_write(path, content)
  end

  defp validate_write_tool(args) do
    cond do
      not is_map_key(args, "name") or not is_binary(args["name"]) or args["name"] == "" ->
        {:error, "Missing required field: 'name' must be a non-empty string"}

      not valid_tool_name?(args["name"]) ->
        {:error, "Invalid tool name: use only letters, numbers, underscores, and hyphens"}

      not is_map_key(args, "description") or not is_binary(args["description"]) ->
        {:error, "Missing required field: 'description' must be a string"}

      not is_map_key(args, "inputSchema") or not is_map(args["inputSchema"]) ->
        {:error, "Missing required field: 'inputSchema' must be a JSON Schema object"}

      args["inputSchema"]["type"] != "object" ->
        {:error, "'inputSchema.type' must be 'object'"}

      not is_map(args["inputSchema"]["properties"] || %{}) ->
        {:error, "'inputSchema.properties' must be an object"}

      Enum.any?(
        Map.keys(args["inputSchema"]["properties"] || %{}),
        &String.starts_with?(&1, "_auth_")
      ) ->
        {:error, "'inputSchema' contains a reserved authentication parameter"}

      has_no_endpoint?(args) ->
        {:error, "Tenant tools must provide an HTTP endpoint"}

      is_map_key(args, "handler") and is_binary(args["handler"]) and args["handler"] != "" ->
        {:error, "Tenant tools cannot define internal handlers"}

      is_map_key(args, "roles") and not valid_string_list?(args["roles"]) ->
        {:error, "'roles' must be a list of strings"}

      is_map_key(args, "permissions") and not valid_string_list?(args["permissions"]) ->
        {:error, "'permissions' must be a list of strings"}

      (url_error = endpoint_url_error(args)) != nil ->
        {:error, url_error}

      true ->
        :ok
    end
  end

  defp endpoint_url_error(args) do
    cond do
      is_map_key(args, "base_url") and is_binary(args["base_url"]) and args["base_url"] != "" ->
        case Acs.MCP.UrlSafety.validate_outbound_url(args["base_url"]) do
          :ok -> nil
          {:error, reason} -> "Invalid base_url: #{reason}"
        end

      is_map_key(args, "endpoint") and is_binary(args["endpoint"]) and args["endpoint"] != "" ->
        endpoint = args["endpoint"]

        if String.starts_with?(endpoint, "http://") or String.starts_with?(endpoint, "https://") do
          case Acs.MCP.UrlSafety.validate_outbound_url(endpoint) do
            :ok -> nil
            {:error, reason} -> "Invalid endpoint URL: #{reason}"
          end
        else
          nil
        end

      true ->
        nil
    end
  end

  defp has_no_endpoint?(args) do
    not is_map_key(args, "endpoint") or
      not is_binary(args["endpoint"]) or
      args["endpoint"] == ""
  end

  defp valid_tool_name?(name) when is_binary(name) do
    Regex.match?(~r/^[a-zA-Z0-9_-]+$/, name)
  end

  defp valid_tool_name?(_), do: false

  defp build_config(args) do
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
      "roles" => args["roles"] || List.wrap(args["role"] || "collaborator"),
      "category" => args["category"] || "custom"
    }

    tool =
      if is_map_key(args, "permissions") and is_list(args["permissions"]) and
           args["permissions"] != [] do
        Map.put(tool, "permissions", args["permissions"])
      else
        tool
      end

    {tool, base_url} = add_endpoint(tool, args)

    # Build the full app config
    %{
      "app" => app,
      "base_url" => base_url,
      "prefix" => false,
      "description" => args["description"],
      "tools" => [tool]
    }
  end

  defp add_endpoint(tool, args) do
    endpoint = args["endpoint"]
    tool = Map.put(tool, "method", "POST")

    if is_binary(args["base_url"]) and args["base_url"] != "" do
      {Map.put(tool, "endpoint", endpoint), args["base_url"]}
    else
      case split_endpoint_url(endpoint) do
        {:ok, base_url, endpoint_path} -> {Map.put(tool, "endpoint", endpoint_path), base_url}
        :error -> {Map.put(tool, "endpoint", endpoint), ""}
      end
    end
  end

  defp persist_database_tool(args, config, org) do
    app = config["app"]
    tool = hd(config["tools"])
    public_id = "#{app}/#{tool["name"]}"

    with :ok <- Acs.MCP.ToolLoader.validate_config(config, {:tenant_db, org}),
         {:ok, previous} <- database_tool_snapshot(org, public_id, allow_missing: true) do
      snapshot = %{
        "app" => app,
        "name" => tool["name"],
        "description" => tool["description"],
        "category" => tool["category"],
        "definition" => config,
        "active" => true
      }

      ledger_opts = [
        org: org,
        actor: database_actor(args),
        source: "mcp",
        message: "Write tenant tool #{public_id}"
      ]

      ledger_opts =
        case previous do
          :missing -> ledger_opts
          %{head_revision_id: head} -> Keyword.put(ledger_opts, :expected_head_revision_id, head)
        end

      case Acs.Artifacts.Ledger.save(:tool, public_id, snapshot, ledger_opts) do
        {:ok, %{revision: revision}} ->
          rollback_previous =
            case previous do
              :missing -> :missing
              %{snapshot: old_snapshot} -> {:existing, old_snapshot}
            end

          {:ok, %{tool: tool["name"], path: "db://#{org}/#{public_id}"},
           {:database, org, public_id, rollback_previous, revision.id}}

        {:error, reason} ->
          {:error, "Failed to persist tenant tool: #{inspect(reason)}"}
      end
    end
  end

  defp database_tool_snapshot(org, public_id, opts \\ []) do
    import Ecto.Query

    projection =
      Acs.Repo.one(
        from tool in Acs.Artifacts.TenantTool,
          join: organization in Acs.Orgs.Organization,
          on: tool.organization_id == organization.id,
          where: organization.slug == ^org and tool.public_id == ^public_id
      )

    allow_missing? = Keyword.get(opts, :allow_missing, false)

    case projection do
      nil ->
        if allow_missing?, do: {:ok, :missing}, else: {:error, :not_found}

      projection ->
        case Jason.decode(projection.snapshot_json) do
          {:ok, snapshot} when is_map(snapshot) ->
            {:ok, %{snapshot: snapshot, head_revision_id: projection.head_revision_id}}

          _ ->
            {:error, :invalid_snapshot}
        end
    end
  end

  defp database_actor(args) do
    case args["_auth_agent_id"] do
      id when is_binary(id) and id != "" -> %{type: "developer_key", id: id}
      _ -> %{type: "system", id: "dynamic_tools"}
    end
  end

  defp write_tool_file(args, yaml_content, credential_org) do
    dir = Acs.Org.tools_dir(credential_org)
    path = Path.join(dir, "#{args["name"]}.yaml")

    if File.dir?(dir) and Acs.Org.safe_path?(dir, path) do
      previous =
        case File.read(path) do
          {:ok, content} -> {:existing, content}
          {:error, :enoent} -> :missing
          {:error, reason} -> {:read_error, reason}
        end

      case previous do
        {:read_error, reason} ->
          {:error, "Failed to read existing tool file: #{inspect(reason)}"}

        _ ->
          case atomic_write(path, yaml_content) do
            :ok -> {:ok, path, previous}
            {:error, reason} -> {:error, "Failed to write tool file: #{inspect(reason)}"}
          end
      end
    else
      {:error, "Tenant tools directory is not safely provisioned: #{dir}"}
    end
  end

  defp atomic_write(path, content) do
    temp_path =
      Path.join(
        Path.dirname(path),
        ".#{Path.basename(path)}.#{System.unique_integer([:positive])}.tmp"
      )

    result =
      case File.open(temp_path, [:write, :binary, :exclusive]) do
        {:ok, device} ->
          write_result =
            with :ok <- IO.binwrite(device, content),
                 :ok <- :file.sync(device) do
              :ok
            end

          close_result = File.close(device)

          with :ok <- write_result,
               :ok <- close_result,
               :ok <- File.rename(temp_path, path) do
            :ok
          end

        {:error, reason} ->
          {:error, reason}
      end

    if result != :ok, do: File.rm(temp_path)
    result
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

  defp credential_org(args) do
    case args["_auth_credential_org_id"] do
      org when is_binary(org) and org != "" -> {:ok, org}
      _ -> {:error, "Missing credential organization authentication context"}
    end
  end

  defp valid_string_list?(list), do: is_list(list) and Enum.all?(list, &is_binary/1)

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
    Enum.flat_map(Enum.sort_by(value, fn {key, _value} -> key end), fn {key, val} ->
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
      Enum.flat_map(Enum.sort_by(map, fn {key, _value} -> key end), fn {k, v} ->
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
    String.contains?(value, ["\n", "\r", "\t", ": "]) or
      String.contains?(value, "#") or
      String.contains?(value, "\"") or
      String.contains?(value, "'") or
      String.starts_with?(value, [" ", "'", "\"", "&", "*", "!", "|", ">", "?", "%", "@"]) or
      String.match?(value, ~r/^(yes|no|true|false|on|off|null|~)$/i) or
      String.match?(value, ~r/^\d+/)
  end

  defp quote_string(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
      |> String.replace("\t", "\\t")

    ~s("#{escaped}")
  end
end
