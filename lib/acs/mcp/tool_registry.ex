defmodule Acs.MCP.ToolRegistry do
  @moduledoc """
  GenServer that manages the lifecycle of MCP tool definitions.

  Tools are loaded from YAML files in the configured tools directory on startup.
  Supports runtime refresh, category-based listing, and tool execution dispatch.

  ## Tool Resolution

  Tools can be:
  - **Internal**: Have a `handler` field → dispatched to that module's `call_tool/2`
  - **External**: Have an `endpoint` + `base_url` → routed through `Acs.MCP.Bridge`

  ## Authorization

  Two-tier RBAC enforced before tool execution:
  1. **Role check**: Tool's `roles` field (from YAML) must include the agent's role
  2. **Permission check** (optional): Tool's `permissions` field (from YAML) must all
     be present in the agent's `_auth_permissions` list. Skipped if either is absent.
  """

  use GenServer
  require Logger

  @error_burst_window_ms 5000

  # --- Client API ---

  @doc """
  Starts the ToolRegistry.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns all loaded tools, optionally filtered by category.
  """
  def list_tools(category \\ nil) do
    GenServer.call(__MODULE__, {:list_tools, category})
  end

  @doc """
  Returns all loaded tools in MCP-compatible format (strips internal fields).
  Optional agent_role filters tools by role. Defaults to "admin" for backward compatibility.
  """
  def list_tools_mcp(agent_role \\ nil) do
    GenServer.call(__MODULE__, {:list_tools_mcp, agent_role || "admin"})
  end

  @doc """
  Returns all unique categories across loaded tools.
  """
  def list_categories do
    GenServer.call(__MODULE__, :list_categories)
  end

  @doc """
  Returns a single tool definition by name, or nil.
  """
  def get_tool(name) do
    GenServer.call(__MODULE__, {:get_tool, name})
  end

  @doc """
  Calls a tool by name with the given arguments.

  For internal tools (handler set), dispatches to the handler module's `call_tool/2`.
  For external tools (endpoint set), routes through `Acs.MCP.Bridge.call_tool/2`.
  """
  def call_tool(name, args) do
    GenServer.call(__MODULE__, {:call_tool, name, args}, 180_000)
  end

  @doc """
  Forces a full reload of all tool definitions from YAML files.
  """
  def refresh do
    GenServer.call(__MODULE__, :refresh, 30_000)
  end

  @doc """
  Returns count of loaded tools per app.
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Lists all registered plugin apps with their metadata, tool counts, and tools.
  """
  def list_plugins do
    GenServer.call(__MODULE__, :list_plugins)
  end

  @doc """
  Checks if a tool is authorized for the given agent role and optional permissions.
  Returns `:ok` or `{:error, reason}`.

  Two-tier check:
  1. Role-based: tool's `roles` field must include `agent_role`
  2. Permission-based (optional): if tool defines `permissions`, all must be
     present in `agent_permissions`. Skipped if either is absent/nil.
  """
  def authorize_tool(name, agent_role, agent_permissions \\ nil) do
    GenServer.call(__MODULE__, {:authorize_tool, name, agent_role, agent_permissions})
  end

  @doc """
  Registers a dynamically created tool (from agent request).
  """
  def register_tool(tool_def) do
    GenServer.call(__MODULE__, {:register_tool, tool_def})
  end

  @doc """
  Approves a tool request and registers the tool in memory.
  Called by the dashboard when an operator approves a request.

  Returns `{:ok, request}` on success, `{:error, reason}` on failure.
  """
  def approve_request(request_id, approved_by) do
    # This is called externally (from dashboard), so GenServer.call is fine
    GenServer.call(__MODULE__, {:approve_request, request_id, approved_by})
  end

  @doc """
  Rejects a tool request.
  """
  def reject_request(request_id, approved_by) do
    GenServer.call(__MODULE__, {:reject_request, request_id, approved_by})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    Logger.info("ToolRegistry starting...")

    state = %{
      # name => tool_def
      tools: %{},
      # app => [tool_defs]
      by_app: %{},
      # category => [tool_defs]
      by_category: %{},
      # list of app configs
      apps: [],
      # app_name => %{version: ..., plugin: ...}
      apps_meta: %{},
      # Telemetry tracking
      # timestamp of last error for burst detection
      last_error_at: nil,
      # current execution chain id
      execution_chain: nil,
      # sequence order within execution chain
      sequence_order: 0
    }

    case load_tools(state) do
      {:ok, new_state} ->
        Logger.info(
          "ToolRegistry initialized with #{map_size(new_state.tools)} tools across #{length(new_state.apps)} apps"
        )

        {:ok, new_state}

      {:error, reason, new_state} ->
        Logger.warning("ToolRegistry initialized with partial load: #{reason}")
        {:ok, new_state}
    end
  end

  @impl true
  def handle_call({:list_tools, category}, _from, state) do
    result =
      case category do
        nil -> Map.values(state.tools)
        cat -> Map.get(state.by_category, cat, [])
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:list_tools_mcp, agent_role}, _from, state) do
    result =
      state.tools
      |> Map.values()
      |> filter_by_role(agent_role)
      |> Enum.map(fn tool ->
        Map.take(tool, ["name", "description", "inputSchema"])
      end)

    {:reply, result, state}
  end

  @impl true
  def handle_call({:authorize_tool, name, agent_role, agent_permissions}, _from, state) do
    tool = Map.get(state.tools, name)

    result =
      case tool do
        nil ->
          {:error, "Unknown tool: #{name}"}

        _ ->
          with :ok <- check_role(tool, name, agent_role),
               :ok <- check_permissions(tool, name, agent_permissions) do
            :ok
          end
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:list_categories, _from, state) do
    {:reply, Map.keys(state.by_category), state}
  end

  @impl true
  def handle_call({:get_tool, name}, _from, state) do
    {:reply, Map.get(state.tools, name), state}
  end

  @impl true
  def handle_call({:call_tool, name, args}, _from, state) do
    case name do
      "request_tool" ->
        result = handle_request_tool_in_state(args, state)

        _ =
          Acs.MetaHarness.OperationLogger.log_tool_result_async(
            "request_tool",
            result,
            0,
            nil,
            nil,
            []
          )

        {:reply, result, state}

      "refresh_tools" ->
        case load_tools(%{state | tools: %{}, by_app: %{}, by_category: %{}, apps: []}) do
          {:ok, new_state} ->
            result = {:ok, %{refreshed: map_size(new_state.tools), apps: new_state.apps}}

            _ =
              Acs.MetaHarness.OperationLogger.log_tool_result_async(
                "refresh_tools",
                result,
                0,
                nil,
                nil,
                []
              )

            {:reply, result, new_state}

          {:error, reason, new_state} ->
            result = {:error, reason}

            _ =
              Acs.MetaHarness.OperationLogger.log_tool_result_async(
                "refresh_tools",
                result,
                0,
                nil,
                nil,
                []
              )

            {:reply, {:error, reason}, new_state}
        end

      _ ->
        # Check if tool exists
        tool_def = Map.get(state.tools, name)
        is_discovered = is_nil(tool_def)

        if is_discovered do
          # Log discovery event
          _ = track_tool_discovery(name, nil, nil)
        end

        case tool_def do
          nil ->
            {:reply, {:error, "Unknown tool: #{name}"}, state}

          _ ->
            start_time = System.monotonic_time(:millisecond)
            result = execute_tool(tool_def, args, state)
            latency_ms = System.monotonic_time(:millisecond) - start_time

            # Extract agent_id and execution_id from args for telemetry
            agent_id = Map.get(args, "agent_id") || Map.get(args, :agent_id)
            execution_id = Map.get(args, "execution_id") || Map.get(args, :execution_id)

            # Track telemetry
            {new_execution_chain, sequence_order} = get_or_create_execution_chain(state)
            is_error = match?({:error, _}, result)
            {new_last_error_at, error_burst} = detect_error_burst(state.last_error_at, is_error)
            params_hash = generate_params_hash(args)
            attempt = get_attempt_number(state, name, is_error)

            # Build telemetry opts
            telemetry_opts = [
              execution_chain_id: new_execution_chain,
              sequence_order: sequence_order,
              attempt: attempt,
              tool_discovered: is_discovered,
              error_burst: error_burst,
              params_hash: params_hash
            ]

            # Log asynchronously to avoid blocking the response
            _ =
              Acs.MetaHarness.OperationLogger.log_tool_result_async(
                name,
                result,
                latency_ms,
                agent_id,
                execution_id,
                telemetry_opts
              )

            # Update state with new chain info
            new_state = %{state |
              execution_chain: new_execution_chain,
              sequence_order: sequence_order,
              last_error_at: new_last_error_at
            }

            {:reply, result, new_state}
        end
    end
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    case load_tools(%{state | tools: %{}, by_app: %{}, by_category: %{}, apps: []}) do
      {:ok, new_state} ->
        Logger.info("ToolRegistry refreshed: #{map_size(new_state.tools)} tools")
        {:reply, :ok, new_state}

      {:error, reason, new_state} ->
        Logger.warning("ToolRegistry refresh partial: #{reason}")
        {:reply, {:error, reason}, new_state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    app_counts =
      Map.new(state.by_app, fn {app, tools} -> {app, length(tools)} end)

    {:reply,
     %{
       total_tools: map_size(state.tools),
       total_apps: length(state.apps),
       categories: Map.keys(state.by_category),
       apps: app_counts
     }, state}
  end

  @impl true
  def handle_call(:list_plugins, _from, state) do
    plugins =
      Enum.map(state.apps, fn app_config ->
        app_name = app_config["app"]
        tools = Map.get(state.by_app, app_name, [])
        meta = Map.get(state.apps_meta, app_name, %{})

        %{
          app: app_name,
          version: meta["version"],
          plugin: meta["plugin"],
          tool_count: length(tools),
          tools: Enum.map(tools, & &1["name"])
        }
      end)
      |> Enum.sort_by(& &1.app)

    {:reply, {:ok, %{plugins: plugins, count: length(plugins)}}, state}
  end

  @impl true
  def handle_call({:register_tool, tool_def}, _from, state) do
    name = tool_def["name"]

    if Map.has_key?(state.tools, name) do
      {:reply, {:error, "Tool '#{name}' already exists"}, state}
    else
      new_tools = Map.put(state.tools, name, tool_def)
      category = tool_def["category"] || "uncategorized"
      by_category = Map.update(state.by_category, category, [tool_def], &[tool_def | &1])
      app = tool_def["app"] || "requested"
      by_app = Map.update(state.by_app, app, [tool_def], &[tool_def | &1])

      new_state = %{state | tools: new_tools, by_category: by_category, by_app: by_app}

      Logger.info("ToolRegistry: registered new tool '#{name}' in category '#{category}'")
      {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:approve_request, request_id, approved_by}, _from, state) do
    case Acs.MCP.ToolRequests.approve_request(request_id, approved_by) do
      {:ok, request} ->
        # Decode the definition and register the tool
        definition = Acs.MCP.ToolRequest.decode_definition(request.definition)

        tool_def =
          Map.merge(
            %{
              "category" => request.category || "requested",
              "level" => 2,
              "app" => "requested",
              "base_url" => "",
              "endpoint" => nil,
              "method" => nil,
              "handler" => nil,
              "params" => definition["params"] || []
            },
            definition
          )

        name = tool_def["name"]

        if Map.has_key?(state.tools, name) do
          {:reply, {:error, "Tool '#{name}' already registered"}, state}
        else
          new_tools = Map.put(state.tools, name, tool_def)
          category = tool_def["category"] || "requested"
          by_category = Map.update(state.by_category, category, [tool_def], &[tool_def | &1])
          app = tool_def["app"] || "requested"
          by_app = Map.update(state.by_app, app, [tool_def], &[tool_def | &1])

          new_state = %{state | tools: new_tools, by_category: by_category, by_app: by_app}

          Logger.info("ToolRegistry: approved tool '#{name}' (request=#{request_id})")

          Acs.broadcast(:tool_request_approved, %{
            request_id: request_id,
            name: name,
            approved_by: approved_by
          })

          {:reply, {:ok, %{status: "approved", tool: name, request_id: request_id}}, new_state}
        end

      {:error, reason} ->
        {:reply, {:error, "Failed to approve: #{inspect(reason)}"}, state}
    end
  end

  @impl true
  def handle_call({:reject_request, request_id, approved_by}, _from, state) do
    case Acs.MCP.ToolRequests.reject_request(request_id, approved_by) do
      {:ok, request} ->
        Logger.info("ToolRegistry: rejected tool request '#{request.name}' (id=#{request_id})")

        Acs.broadcast(:tool_request_rejected, %{
          request_id: request_id,
          name: request.name,
          rejected_by: approved_by
        })

        {:reply, {:ok, %{status: "rejected", request_id: request_id}}, state}

      {:error, reason} ->
        {:reply, {:error, "Failed to reject: #{inspect(reason)}"}, state}
    end
  end

  # --- Private ---

  defp check_role(tool, name, agent_role) do
    roles = tool["roles"] || ["admin"]

    if agent_role in roles do
      :ok
    else
      {:error, "Role '#{agent_role}' is not authorized to use tool '#{name}'"}
    end
  end

  defp check_permissions(_tool, _name, nil), do: :ok
  defp check_permissions(_tool, _name, []), do: :ok

  defp check_permissions(tool, name, agent_permissions) when is_list(agent_permissions) do
    required = tool["permissions"]

    cond do
      is_nil(required) or required == [] ->
        :ok

      Enum.all?(required, fn perm -> perm in agent_permissions end) ->
        :ok

      true ->
        missing = Enum.reject(required, fn perm -> perm in agent_permissions end)
        {:error, "Missing required permissions for '#{name}': #{Enum.join(missing, ", ")}"}
    end
  end

  defp check_permissions(_tool, _name, _agent_permissions), do: :ok

  defp load_tools(state) do
    case Acs.MCP.ToolLoader.load_all() do
      {:ok, tools_by_app} when tools_by_app == %{} ->
        Logger.warning("No tool definitions loaded - check MCP_TOOLS_PATH")
        {:error, "No tools loaded", state}

      {:ok, tools_by_app} ->
        {tools, by_app, by_category, apps, apps_meta} =
          Enum.reduce(
            tools_by_app,
            {state.tools, state.by_app, state.by_category, state.apps, state.apps_meta},
            fn {app_name, app_config}, {tools_acc, by_app_acc, by_cat_acc, apps_acc, apps_meta_acc} ->
              tool_defs = Acs.MCP.ToolLoader.to_mcp_tools(app_config)

              # Index by name
              tools_acc =
                Enum.reduce(tool_defs, tools_acc, fn td, acc ->
                  Map.put(acc, td["name"], td)
                end)

              # Index by category
              by_cat_acc =
                Enum.reduce(tool_defs, by_cat_acc, fn td, acc ->
                  cat = td["category"] || "uncategorized"
                  Map.update(acc, cat, [td], fn existing -> [td | existing] end)
                end)

              # Index by app
              by_app_acc = Map.put(by_app_acc, app_name, tool_defs)

              # Collect app metadata
              app_meta = %{
                "version" => app_config["version"],
                "plugin" => app_config["plugin"]
              }

              apps_meta_acc = Map.put(apps_meta_acc, app_name, app_meta)

              {tools_acc, by_app_acc, by_cat_acc, [app_config | apps_acc], apps_meta_acc}
            end
          )

        new_state = %{state | tools: tools, by_app: by_app, by_category: by_category, apps: apps, apps_meta: apps_meta}

        {:ok, new_state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp execute_tool(tool_def, args, state) do
    name = tool_def["name"]

    case name do
      "list_categories" ->
        {:ok, %{categories: Map.keys(state.by_category)}}

      "list_tools" ->
        category = args["category"]
        # Default to level 1 (essentials)
        level = args["level"] || 1
        tools = list_tools(state, category, level)
        {:ok, %{category: category, level: level, tools: tools, count: length(tools)}}

      "help" ->
        acs_help(state, args)

      _ ->
        execute_external_tool(tool_def, args, state)
    end
  end

  defp list_tools(state, nil, level), do: filter_by_level(Map.values(state.tools), level)
  defp list_tools(state, category, _level), do: Map.get(state.by_category, category, [])

  defp filter_by_level(tools, level) do
    Enum.filter(tools, fn t -> (t["level"] || 2) <= level end)
  end

  defp filter_by_role(tools, agent_role) when is_binary(agent_role) do
    Enum.filter(tools, fn t ->
      roles = t["roles"] || ["admin"]
      agent_role in roles
    end)
  end

  defp acs_help(state, args) do
    category_filter = args["category"]
    level_filter = args["level"]

    all_tools = Map.values(state.tools)
    categories = Map.keys(state.by_category)

    filtered_tools =
      all_tools
      |> Enum.filter(fn t ->
        matches_category = is_nil(category_filter) || t["category"] == category_filter
        tool_level = t["level"] || 2
        matches_level = is_nil(level_filter) || tool_level <= level_filter
        matches_category and matches_level
      end)

    tools_by_category =
      filtered_tools
      |> Enum.group_by(&(Map.get(&1, "category") || "uncategorized"))
      |> Enum.map(fn {cat, tools} ->
        {cat,
         Enum.map(tools, fn t ->
           %{
             name: t["name"],
             level: t["level"] || 2,
             description: t["description"],
             params: (t["params"] || []) |> Enum.map(fn p -> p["name"] end),
             required_params:
               (t["params"] || [])
               |> Enum.filter(fn p -> p["required"] end)
               |> Enum.map(fn p -> p["name"] end)
           }
         end)
         |> Enum.sort_by(& &1.name)}
      end)
      |> Enum.sort_by(fn {cat, _} -> cat end)
      |> Enum.into(%{})

    total_count = length(filtered_tools)

    {:ok,
     %{
       total_tools: total_count,
       categories: %{
         available: categories,
         filtered: Map.keys(tools_by_category)
       },
       tools: tools_by_category
     }}
  end

  defp execute_external_tool(tool_def, args, _state) do
    cond do
      tool_def["handler"] && tool_def["handler"] != "" ->
        handler_mod = tool_def["handler"]

        case fetch_handler_module(handler_mod) do
          {:ok, module} ->
            apply(module, :call_tool, [tool_def["name"], args])

          {:error, reason} ->
            {:error, "Handler module error: #{reason}"}
        end

      tool_def["endpoint"] && tool_def["base_url"] && tool_def["base_url"] != "" ->
        Acs.MCP.Bridge.call_tool(tool_def, args)

      true ->
        result = Acs.MCP.Tools.call_tool(tool_def["name"], args)
        normalize_tool_result(result)
    end
  end

  # Safely convert handler module string to atom, catching invalid modules
  defp fetch_handler_module(handler_mod) do
    module_name = "Elixir.#{handler_mod}"

    with true <- String.split(module_name, ".") |> Enum.all?(&valid_module_component?/1),
         {:module, mod} <- Code.ensure_loaded(String.to_existing_atom(module_name)) do
      {:ok, mod}
    else
      false -> {:error, "Invalid module name components"}
      {:error, reason} -> {:error, "Module not loaded: #{inspect(reason)}"}
    end
  end

  defp valid_module_component?(""), do: false

  defp valid_module_component?(s) do
    Regex.match?(~r/^[A-Z][a-zA-Z0-9_]*$/, s)
  end

  # Normalize various return formats to {:ok, ...} or {:error, ...}
  defp normalize_tool_result({:ok, _} = result), do: result
  defp normalize_tool_result({:error, _} = result), do: result
  defp normalize_tool_result(:ok), do: {:ok, %{status: "ok"}}
  defp normalize_tool_result({:ok}), do: {:ok, %{status: "ok"}}
  defp normalize_tool_result(nil), do: {:ok, %{status: "ok"}}
  defp normalize_tool_result(other), do: {:ok, %{status: "ok", result: inspect(other)}}

  defp handle_request_tool_in_state(args, _state) do
    definition = args["definition"]
    agent_id = args["agent_id"] || "unknown"

    cond do
      is_nil(definition) ->
        {:error, "Missing required parameter: 'definition'"}

      not is_map(definition) ->
        {:error, "'definition' must be a JSON object"}

      not is_map_key(definition, "name") ->
        {:error, "Tool definition must include a 'name' field"}

      true ->
        case Acs.MCP.ToolRequests.create_request(agent_id, definition) do
          {:ok, request} ->
            Logger.info("ToolRegistry: tool request created '#{request.name}' (id=#{request.id})")

            Acs.broadcast(:tool_request_created, %{
              request_id: request.id,
              name: request.name,
              agent_id: agent_id
            })

            {:ok,
             %{
               status: "pending",
               message:
                 "Tool request '#{request.name}' has been submitted for approval. " <>
                   "A human operator will review and approve it via the ACS dashboard.",
               request_id: request.id,
               tool: request.name
             }}

          {:error, changeset} ->
            errors =
              changeset.errors
              |> Enum.map(fn {field, {msg, _}} -> "#{field}: #{msg}" end)
              |> Enum.join("; ")

            {:error, "Failed to create tool request: #{errors}"}
        end
    end
  end

  defp get_or_create_execution_chain(state) do
    chain_id = state.execution_chain || generate_uuid()
    sequence = if state.execution_chain, do: state.sequence_order + 1, else: 0
    {chain_id, sequence}
  end

  defp generate_uuid do
    # Generate a UUID-like string using crypto
    bin = :crypto.strong_rand_bytes(16)
    <<a::binary-4, b::binary-2, c::binary-2, d::binary-2, e::binary-6>> = bin
    "#{a}-#{b}-#{c}-#{d}-#{e}"
  end

  defp generate_params_hash(args) when is_map(args) do
    case Jason.encode(args) do
      {:ok, json} ->
        :crypto.hash(:sha256, json) |> Base.encode16() |> String.slice(0, 16)

      _ ->
        :crypto.hash(:sha256, inspect(args)) |> Base.encode16() |> String.slice(0, 16)
    end
  end

  defp generate_params_hash(_), do: nil

  defp detect_error_burst(last_error_at, false = _is_error) do
    # No error this time, just update timestamp if there was an error
    {last_error_at, false}
  end

  defp detect_error_burst(last_error_at, true = _is_error) do
    now = System.monotonic_time(:millisecond)

    if is_nil(last_error_at) do
      {now, false}
    else
      elapsed = now - last_error_at

      if elapsed < @error_burst_window_ms do
        {now, true}
      else
        {now, false}
      end
    end
  end

  defp get_attempt_number(_state, _tool_name, false = _is_error) do
    1
  end

  defp get_attempt_number(_state, _tool_name, true = _is_error) do
    # For errors, we'd track attempt number per tool
    # For now, return 1 on first failure - a more complete implementation
    # would track this in persistent state
    1
  end

  @doc """
  Tracks when an agent requests a tool that doesn't exist.
  """
  def track_tool_discovery(tool_name, agent_id, execution_id) do
    Acs.MetaHarness.OperationLogger.log_async(
      tool_name,
      :discovery,
      nil,
      nil,
      nil,
      agent_id,
      execution_id,
      tool_discovered: true
    )
  end
end
