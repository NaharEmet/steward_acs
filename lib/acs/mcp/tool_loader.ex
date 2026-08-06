defmodule Acs.MCP.ToolLoader do
  @moduledoc false

  @type scope :: {:tenant, String.t()} | :shared
  @type source ::
          {:tenant, String.t(), String.t()} | {:tenant_db, String.t()} | {:shared, String.t()}

  @doc "Returns legacy shared tool paths for internal callers."
  def tools_paths do
    shared_paths()
    |> Enum.filter(&File.dir?/1)
  end

  @doc "Returns typed, trusted tool sources."
  @spec sources() :: [source()]
  def sources do
    tenant_sources =
      if Acs.Org.multi_tenant?() do
        Enum.map(known_orgs(), &{:tenant_db, &1})
      else
        known_orgs()
        |> Enum.map(fn org -> {:tenant, org, Acs.Org.tools_dir(org)} end)
        |> Enum.filter(fn {:tenant, _org, path} -> trusted_dir?(path) end)
      end

    shared_sources =
      shared_paths()
      |> Enum.filter(&trusted_dir?/1)
      |> Enum.map(&{:shared, &1})

    (tenant_sources ++ shared_sources)
    |> Enum.uniq()
    |> Enum.sort_by(&source_sort_key/1)
  end

  # Reject dirs that sit under the vault lexically but symlink-escape it.
  # Shared tool roots outside the vault remain allowed.
  defp trusted_dir?(path) do
    File.dir?(path) and not vault_symlink_escape?(path)
  end

  defp vault_symlink_escape?(path) do
    case Acs.Org.vault_base() do
      nil ->
        false

      base ->
        expanded = Path.expand(path)
        under_vault? = expanded == base or String.starts_with?(expanded, base <> "/")
        under_vault? and not Acs.Org.safe_path?(base, path)
    end
  end

  @doc "Loads every configured source without flattening its scope."
  @spec load_scoped() :: {:ok, [map()]} | {:error, String.t()}
  def load_scoped do
    sources()
    |> Enum.reduce_while({:ok, []}, fn source, {:ok, configs} ->
      case load_source(source) do
        {:ok, source_configs} -> {:cont, {:ok, configs ++ source_configs}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, configs} -> validate_scoped_duplicates(configs)
      error -> error
    end
  end

  @doc "Legacy flattened shared-tool view for internal callers."
  def load_all do
    with {:ok, configs} <- load_scoped() do
      configs
      |> Enum.filter(&(&1["_scope"] == :shared))
      |> Enum.reduce(%{}, fn config, acc ->
        Map.update(acc, config["app"], config, fn existing ->
          Map.update(existing, "tools", config["tools"], &(&1 ++ config["tools"]))
        end)
      end)
      |> then(&{:ok, &1})
    end
  end

  @doc "Loads and validates a single YAML definition file as a trusted shared source."
  def load_file(file_path), do: load_file(file_path, {:shared, Path.dirname(file_path)})

  @doc "Loads and validates a single YAML definition file from a typed source."
  @spec load_file(String.t(), source()) :: {:ok, map()} | {:error, String.t()}
  def load_file(file_path, source) do
    with {:ok, config} <- YamlElixir.read_from_file(file_path),
         true <- is_map(config) || {:error, "Invalid YAML structure: expected a map at root"},
         :ok <- validate_config(config, source),
         {:ok, digest} <- digest_file(file_path) do
      {:ok,
       config
       |> Map.put("_scope", source_scope(source))
       |> Map.put("_source", %{
         path: Path.expand(file_path),
         scope: source_scope(source),
         digest: digest
       })}
    else
      {:error, reason} -> {:error, format_file_error(file_path, reason)}
      false -> {:error, "Invalid YAML structure: expected a map at root"}
    end
  end

  @doc "Validates a tool configuration map using legacy shared-source semantics."
  def validate_config(config), do: validate_config(config, {:shared, "legacy"})

  @doc "Validates a tool configuration map against its trusted source."
  @spec validate_config(map(), source()) :: :ok | {:error, String.t()}
  def validate_config(config, source) when is_map(config) do
    cond do
      Map.has_key?(config, "org") or Map.has_key?(config, "scope") ->
        {:error, "Tool source ownership must not be declared in YAML"}

      not is_binary(config["app"]) or config["app"] == "" ->
        {:error, "Missing required field: 'app'"}

      not is_list(config["tools"]) or config["tools"] == [] ->
        {:error, "'tools' must be a non-empty list"}

      true ->
        errors = validate_app_meta(config) ++ validate_tools(config["tools"], source)
        if errors == [], do: :ok, else: {:error, Enum.join(errors, "; ")}
    end
  end

  def validate_config(_config, _source),
    do: {:error, "Invalid YAML structure: expected a map at root"}

  @doc "Converts a scoped loaded config into MCP tool definitions."
  def to_mcp_tools(app_config) do
    base_url = app_config["base_url"] || ""
    app_name = app_config["app"]

    Enum.map(app_config["tools"], fn tool ->
      params = tool["params"] || params_from_schema(tool["input_schema"])

      input_schema =
        if is_map(tool["input_schema"]) do
          tool["input_schema"]
        else
          %{
            "type" => "object",
            "properties" => build_properties(params),
            "required" => build_required(params)
          }
        end

      %{
        "name" =>
          if(app_config["prefix"] == false, do: tool["name"], else: "#{app_name}_#{tool["name"]}"),
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
        "roles" => tool["roles"],
        "timeout" => tool["timeout"],
        "response_transform" => tool["response_transform"],
        "_app_meta" => %{"version" => app_config["version"], "plugin" => app_config["plugin"]},
        "_scope" => app_config["_scope"],
        "_source" => app_config["_source"]
      }
    end)
  end

  @doc false
  def load_scope(sources) when is_list(sources) do
    sources
    |> Enum.reduce_while({:ok, []}, fn source, {:ok, configs} ->
      case load_source(source) do
        {:ok, source_configs} -> {:cont, {:ok, configs ++ source_configs}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, configs} -> validate_scoped_duplicates(configs)
      error -> error
    end
  end

  @doc false
  def load_source({:tenant_db, org}), do: load_database_source(org)

  def load_source(source) do
    source
    |> source_path()
    |> tool_files()
    |> Enum.reduce_while({:ok, []}, fn file, {:ok, configs} ->
      case load_file(file, source) do
        {:ok, config} -> {:cont, {:ok, configs ++ [config]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp load_database_source(org) do
    import Ecto.Query

    rows =
      Acs.Repo.all(
        from tool in Acs.Artifacts.TenantTool,
          join: organization in Acs.Orgs.Organization,
          on: tool.organization_id == organization.id,
          where: organization.slug == ^org,
          order_by: [asc: tool.app, asc: tool.name]
      )

    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, configs} ->
      with {:ok, snapshot} <- Jason.decode(row.snapshot_json),
           true <- Map.get(snapshot, "active", true),
           {:ok, config} <- database_definition(snapshot, row),
           :ok <- validate_config(config, {:tenant_db, org}) do
        source = %{
          path: "db://#{org}/#{row.public_id}",
          scope: {:tenant, org},
          digest: row.head_revision_id
        }

        config =
          config
          |> Map.put("_scope", {:tenant, org})
          |> Map.put("_source", source)

        {:cont, {:ok, configs ++ [config]}}
      else
        false ->
          {:cont, {:ok, configs}}

        {:error, reason} ->
          {:halt, {:error, "Invalid tenant tool #{row.public_id}: #{inspect(reason)}"}}
      end
    end)
  rescue
    error -> {:error, "Failed to load tenant tools for #{org}: #{Exception.message(error)}"}
  end

  defp database_definition(%{"definition" => %{"tools" => _} = config}, _row),
    do: {:ok, config}

  defp database_definition(%{"definition" => tool}, row) when is_map(tool),
    do: {:ok, %{"app" => row.app, "prefix" => false, "tools" => [tool]}}

  defp database_definition(_, _row), do: {:error, :invalid_definition}

  defp tool_files(path) do
    [Path.join(path, "*.yaml"), Path.join(path, "*.yml")]
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.filter(fn file ->
      Acs.Org.safe_path?(path, file) and
        match?({:ok, %File.Stat{type: :regular}}, File.lstat(file))
    end)
    |> Enum.sort()
  end

  defp validate_scoped_duplicates(configs) do
    duplicates =
      configs
      |> Enum.flat_map(fn config ->
        config
        |> to_mcp_tools()
        |> Enum.map(fn tool ->
          {tool["_scope"], tool["name"], Map.fetch!(tool["_source"], :path)}
        end)
      end)
      |> Enum.group_by(fn {scope, name, _path} -> {scope, name} end)
      |> Enum.filter(fn {_key, entries} -> length(entries) > 1 end)
      |> Enum.sort_by(fn {{scope, name}, _entries} -> {scope_sort_key(scope), name} end)

    case duplicates do
      [] ->
        {:ok, configs}

      [{{scope, name}, entries} | _] ->
        paths = entries |> Enum.map(&elem(&1, 2)) |> Enum.sort() |> Enum.join(", ")
        {:error, "Duplicate tool '#{name}' in #{format_scope(scope)}: #{paths}"}
    end
  end

  defp validate_app_meta(config) do
    []
    |> maybe_invalid(config, "version", &is_nonempty_binary?/1, "'version' must be a string")
    |> maybe_invalid(config, "plugin", &is_map/1, "'plugin' must be a map")
    |> then(fn errors ->
      if is_map(config["plugin"]) do
        Enum.reduce(["source", "description", "homepage"], errors, fn key, acc ->
          if Map.has_key?(config["plugin"], key) and
               not is_nonempty_binary?(config["plugin"][key]) do
            acc ++ ["'plugin.#{key}' must be a string"]
          else
            acc
          end
        end)
      else
        errors
      end
    end)
  end

  defp validate_tools(tools, source) do
    tools
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {tool, index} ->
      case validate_tool(tool, source) do
        :ok -> []
        {:error, reason} -> ["Tool ##{index}: #{reason}"]
      end
    end)
  end

  defp validate_tool(tool, source) when is_map(tool) do
    cond do
      Map.has_key?(tool, "org") or Map.has_key?(tool, "scope") ->
        {:error, "Tool source ownership must not be declared in YAML"}

      not is_nonempty_binary?(tool["name"]) ->
        {:error, "Missing required field: 'name'"}

      not is_binary(tool["description"]) ->
        {:error, "Tool '#{tool["name"]}' 'description' must be a string"}

      has_handler?(tool) and source_scope(source) != :shared ->
        {:error, "Tenant tools must use endpoints, not internal handlers"}

      has_handler?(tool) and not trusted_handler?(tool["handler"]) ->
        {:error, "Handler '#{tool["handler"]}' is not allowed for shared tools"}

      not has_handler?(tool) and not has_endpoint?(tool) ->
        {:error, "Tool '#{tool["name"]}' must have either 'handler' or 'endpoint' + 'method'"}

      has_endpoint?(tool) and not is_binary(tool["endpoint"]) ->
        {:error, "Tool '#{tool["name"]}' 'endpoint' must be a string"}

      has_endpoint?(tool) and not is_binary(tool["method"]) ->
        {:error, "Tool '#{tool["name"]}' 'method' must be a string"}

      has_endpoint?(tool) and tool["method"] not in ["GET", "POST", "PUT", "DELETE", "PATCH"] ->
        {:error, "Tool '#{tool["name"]}' 'method' must be GET, POST, PUT, DELETE, or PATCH"}

      Map.has_key?(tool, "category") and not is_binary(tool["category"]) ->
        {:error, "Tool '#{tool["name"]}' 'category' must be a string"}

      Map.has_key?(tool, "level") and not is_integer(tool["level"]) ->
        {:error, "Tool '#{tool["name"]}' 'level' must be an integer"}

      not valid_string_list?(tool, "roles") ->
        {:error, "Tool '#{tool["name"]}' 'roles' must be a list of strings"}

      not valid_string_list?(tool, "permissions") ->
        {:error, "Tool '#{tool["name"]}' 'permissions' must be a list of strings"}

      Map.has_key?(tool, "params") and not is_list(tool["params"]) ->
        {:error, "Tool '#{tool["name"]}' 'params' must be a list"}

      Map.has_key?(tool, "input_schema") and not is_map(tool["input_schema"]) ->
        {:error, "Tool '#{tool["name"]}' 'input_schema' must be a map"}

      is_map(tool["input_schema"]) and tool["input_schema"]["type"] != "object" ->
        {:error, "Tool '#{tool["name"]}' 'input_schema.type' must be 'object'"}

      is_map(tool["input_schema"]) and
          not is_map(tool["input_schema"]["properties"] || %{}) ->
        {:error, "Tool '#{tool["name"]}' 'input_schema.properties' must be a map"}

      is_map(tool["input_schema"]) and
          Enum.any?(
            Map.keys(tool["input_schema"]["properties"] || %{}),
            &String.starts_with?(&1, "_auth_")
          ) ->
        {:error, "Tool '#{tool["name"]}' input schema contains a reserved auth parameter"}

      true ->
        errors =
          if is_map(tool["input_schema"]), do: [], else: validate_params(tool["params"] || [])

        if errors == [], do: :ok, else: {:error, Enum.join(errors, "; ")}
    end
  end

  defp validate_tool(_tool, _source), do: {:error, "must be a map"}

  defp validate_params(params) do
    params
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {param, index} ->
      cond do
        not is_map(param) ->
          ["Param ##{index}: must be a map"]

        not is_nonempty_binary?(param["name"]) ->
          ["Param ##{index}: missing 'name'"]

        String.starts_with?(param["name"], "_auth_") ->
          ["Param '#{param["name"]}': reserved auth name"]

        not is_nonempty_binary?(param["type"]) ->
          ["Param '#{param["name"]}': missing 'type'"]

        true ->
          []
      end
    end)
  end

  defp params_from_schema(%{"properties" => properties} = schema) when is_map(properties) do
    required = MapSet.new(schema["required"] || [])

    properties
    |> Enum.reject(fn {name, _definition} -> String.starts_with?(name, "_auth_") end)
    |> Enum.map(fn {name, definition} ->
      definition
      |> Map.take(["type", "description", "items"])
      |> Map.put("name", name)
      |> Map.put("required", MapSet.member?(required, name))
    end)
  end

  defp params_from_schema(_), do: []

  defp build_properties(params) do
    Map.new(params, fn param ->
      type = param["type"]
      description = param["description"] || ""

      property =
        case type do
          "array" ->
            %{
              "type" => "array",
              "items" => param["items"] || %{"type" => "string"},
              "description" => description
            }

          "json" ->
            %{"type" => "object", "description" => description}

          "boolean" ->
            %{"type" => "boolean", "description" => description}

          _ ->
            %{"type" => type, "description" => description}
        end

      {param["name"], property}
    end)
  end

  defp build_required(params),
    do: params |> Enum.filter(& &1["required"]) |> Enum.map(& &1["name"])

  defp shared_paths do
    env_paths = System.get_env("MCP_TOOLS_PATH") |> parse_env_paths()

    config_paths =
      case Application.get_env(:steward_acs, __MODULE__, []) do
        config when is_list(config) ->
          (config[:shared_tools_paths] || config[:tools_paths] || [config[:tools_path]])
          |> List.wrap()
          |> Enum.filter(&is_binary/1)

        _ ->
          []
      end

    (env_paths ++ config_paths ++ [default_tools_path()])
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp known_orgs do
    configured = [Acs.Org.configured(), Acs.Org.current()]

    orgs =
      if Acs.Org.multi_tenant?() do
        Acs.Orgs.list_all()
        |> Enum.filter(&(&1.provisioning_status == "ready"))
        |> Enum.map(& &1.slug)
      else
        []
      end

    (configured ++ orgs) |> Enum.filter(&is_nonempty_binary?/1) |> Enum.uniq() |> Enum.sort()
  end

  defp parse_env_paths(nil), do: []

  defp parse_env_paths(paths),
    do:
      paths
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

  defp default_tools_path,
    do: Path.expand("../../../acs/acstools", Application.app_dir(:steward_acs))

  defp source_path({:tenant, _org, path}), do: path
  defp source_path({:shared, path}), do: path
  defp source_scope({:tenant, org, _path}), do: {:tenant, org}
  defp source_scope({:tenant_db, org}), do: {:tenant, org}
  defp source_scope({:shared, _path}), do: :shared
  defp source_sort_key({:tenant, org, path}), do: {0, org, Path.expand(path)}
  defp source_sort_key({:tenant_db, org}), do: {0, org, "db"}
  defp source_sort_key({:shared, path}), do: {1, "", Path.expand(path)}
  defp scope_sort_key(:shared), do: {1, ""}
  defp scope_sort_key({:tenant, org}), do: {0, org}
  defp format_scope(:shared), do: "shared scope"
  defp format_scope({:tenant, org}), do: "tenant '#{org}'"

  defp trusted_handler?(handler) when is_binary(handler) do
    Application.get_env(:steward_acs, __MODULE__, [])
    |> Keyword.get(:trusted_handler_modules, [])
    |> Enum.map(&to_string/1)
    |> Enum.member?(handler)
  end

  defp trusted_handler?(_), do: false
  defp has_handler?(tool), do: is_binary(tool["handler"]) and tool["handler"] != ""
  defp has_endpoint?(tool), do: not is_nil(tool["endpoint"])

  defp valid_string_list?(tool, key),
    do: not Map.has_key?(tool, key) or (is_list(tool[key]) and Enum.all?(tool[key], &is_binary/1))

  defp is_nonempty_binary?(value), do: is_binary(value) and value != ""

  defp maybe_invalid(errors, map, key, validator, message),
    do:
      if(Map.has_key?(map, key) and not validator.(map[key]),
        do: errors ++ [message],
        else: errors
      )

  defp digest_file(path) do
    case File.read(path) do
      {:ok, content} ->
        {:ok, :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)}

      {:error, reason} ->
        {:error, "cannot read source for digest: #{inspect(reason)}"}
    end
  end

  defp format_file_error(file, reason), do: "Failed to load tool file #{file}: #{inspect(reason)}"
end
