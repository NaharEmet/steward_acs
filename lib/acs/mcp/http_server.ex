defmodule Acs.MCP.HTTPServer do
  @moduledoc """
  MCP Server implementation using HTTP/SSE transport.
  Handles JSON-RPC requests over HTTP and Server-Sent Events for notifications.

  ## Authentication Context

  The `MCPAuth` plug injects `agent_role`, `agent_org_id`, and `agent_permissions`
  into conn.assigns. These are forwarded to `Protocol.handle_message/4` for
  RBAC enforcement:
  - `agent_role` — role-based access control (tool's `roles` field)
  - `agent_permissions` — permission-based RBAC (tool's `permissions` field)
  """
  use Plug.Router

  alias Acs.MCP.LogStore
  alias Acs.MCP.Protocol

  require Logger

  plug(:match)
  plug(Acs.MCP.Plugs.MCPAuth)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:dispatch)

  # MCP Endpoints
  post "/mcp/v1/messages" do
    conn = fetch_query_params(conn)
    session_id = conn.query_params["session_id"] || generate_session_id()

    Logger.debug("MCP HTTP: received body_params=#{inspect(conn.body_params)}")

    case conn.body_params do
      %{} = params ->
        agent_role = conn.assigns[:agent_role] || "admin"
        agent_org_id = conn.assigns[:agent_org_id]
        agent_permissions = conn.assigns[:agent_permissions]

        case Protocol.handle_message(params, agent_role, agent_org_id, agent_permissions) do
          {:sleep, id, agent_id, timeout} ->
            Logger.info(
              "MCP HTTP: agent #{agent_id} sleeping (long-poll, timeout=#{inspect(timeout)})"
            )

            result = Acs.MCP.Tools.CoreHandlers.sleep_and_wait(agent_id, timeout)

            response =
              case result do
                {:ok, data} ->
                  Protocol.success_response(id, %{
                    "content" => [
                      %{"type" => "text", "text" => Jason.encode!(data, pretty: true)}
                    ]
                  })

                {:error, reason} ->
                  Protocol.success_response(id, %{
                    "content" => [%{"type" => "text", "text" => "Error: #{inspect(reason)}"}],
                    "isError" => true
                  })
              end

            conn
            |> put_resp_content_type("application/json")
            |> put_resp_header("x-mcp-session-id", session_id)
            |> send_resp(200, Jason.encode!(response))

          {:ok, response} ->
            Logger.debug("MCP HTTP: response=#{inspect(response)}")

            conn
            |> put_resp_content_type("application/json")
            |> put_resp_header("x-mcp-session-id", session_id)
            |> send_resp(200, Jason.encode!(response))

          {:error, reason} ->
            error = Protocol.error_response(nil, -32700, "Parse error", reason)

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(400, Jason.encode!(error))
        end

      _ ->
        conn |> send_resp(400, ~s({"error": "Invalid JSON"}))
    end
  end

  # Log ingestion from external services
  post "/api/logs/ingest" do
    body = conn.body_params

    case body do
      %{"logs" => logs} when is_list(logs) ->
        # Batch mode: store multiple log entries
        results = Enum.map(logs, &process_log_entry/1)

        success_count = Enum.count(results, &(&1 == :ok))

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{status: "ok", stored: success_count, total: length(logs)}))

      %{} = log_entry when map_size(log_entry) > 0 ->
        case process_log_entry(log_entry) do
          :ok ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(%{status: "ok"}))

          {:error, reason} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(500, Jason.encode!(%{status: "error", reason: inspect(reason)}))
        end

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "Invalid log entry. Expected JSON with 'message' and optional 'level', 'service', 'component', 'metadata'"}))
    end
  end

  # Log query endpoint for external services
  get "/api/logs" do
    conn = fetch_query_params(conn)
    params = conn.query_params

    opts = []
    opts = if params["level"], do: Keyword.put(opts, :level, String.to_existing_atom(params["level"])), else: opts

    opts =
      if params["limit"] do
        case Integer.parse(params["limit"]) do
          {n, ""} when n > 0 -> Keyword.put(opts, :limit, n)
          _ -> conn |> send_resp(400, Jason.encode!(%{error: "Invalid limit: must be positive integer"})) |> halt()
        end
      else
        opts
      end

    opts = if params["component"], do: Keyword.put(opts, :component, params["component"]), else: opts
    opts = if params["search"], do: Keyword.put(opts, :search, params["search"]), else: opts
    opts = if params["service"], do: Keyword.put(opts, :service, params["service"]), else: opts
    opts = if params["workflow_id"], do: Keyword.put(opts, :workflow_id, params["workflow_id"]), else: opts
    opts = if params["execution_id"], do: Keyword.put(opts, :execution_id, params["execution_id"]), else: opts
    opts = if params["since"], do: Keyword.put(opts, :since, params["since"]), else: opts
    opts = if params["until"], do: Keyword.put(opts, :until, params["until"]), else: opts

    opts =
      if params["offset"] do
        case Integer.parse(params["offset"]) do
          {n, ""} when n >= 0 -> Keyword.put(opts, :offset, n)
          _ -> conn |> send_resp(400, Jason.encode!(%{error: "Invalid offset: must be non-negative integer"})) |> halt()
        end
      else
        opts
      end

    opts = if params["compact"] == "true", do: Keyword.put(opts, :compact, true), else: opts

    mode = params["mode"] || "list"

    result = LogStore.get_logs(opts, mode)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(result))
  end

  # Log context endpoint - get entries surrounding a specific log entry
  get "/api/logs/context/:id" do
    conn = fetch_query_params(conn)

    entry_id =
      case Integer.parse(id) do
        {n, ""} -> n
        _ ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(400, Jason.encode!(%{error: "Invalid entry id: must be an integer"}))
          |> halt()
      end

    window_size =
      case conn.query_params["window_size"] do
        nil -> 30
        ws ->
          case Integer.parse(ws) do
            {n, ""} when n > 0 -> n
            _ ->
              conn
              |> put_resp_content_type("application/json")
              |> send_resp(400, Jason.encode!(%{error: "Invalid window_size: must be positive integer"}))
              |> halt()
          end
      end

    result = LogStore.get_context_before(entry_id, window_size)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(result))
  end

  # Health check
  get "/mcp/health" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{status: "healthy", timestamp: DateTime.utc_now()}))
  end

  # Task API for external apps
  post "/api/tasks" do
    body = conn.body_params

    case body do
      %{"title" => title, "created_by_agent" => agent_id} when is_binary(title) and is_binary(agent_id) ->
        case Acs.create_task(body, agent_id) do
          {:ok, task} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(201, Jason.encode!(%{status: "created", task_id: task.id, task: task}))

          {:warn, task, similar} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(201, Jason.encode!(%{status: "created_with_warning", task_id: task.id, task: task, similar_tasks: similar}))

          {:error, reason} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(400, Jason.encode!(%{status: "error", reason: inspect(reason)}))
        end

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "Missing required fields: title, created_by_agent"}))
    end
  end

  # Bump/update a task
  patch "/api/tasks/:id" do
    body = conn.body_params

    case Acs.bump_task(id, body || %{}) do
      {:ok, task} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{status: "updated", task_id: task.id, event_count: task.event_count}))

      {:error, reason} ->
        status = if reason == :task_not_found, do: 404, else: 400

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(%{status: "error", reason: inspect(reason)}))
    end
  end

  # Catch-all
  match _ do
    conn |> send_resp(404, ~s({"error": "Not found"}))
  end

  defp generate_session_id do
    "http_#{System.system_time(:millisecond)}_#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
  end

  defp process_log_entry(log_entry) do
    level = parse_log_level(Map.get(log_entry, "level", "info"))
    service = Map.get(log_entry, "service", "unknown")
    component = Map.get(log_entry, "component", "external")
    message = Map.get(log_entry, "message", "")

    metadata =
      log_entry
      |> Map.get("metadata", %{})
      |> normalize_metadata()
      |> enrich_metadata(service, component)

    LogStore.store_log(level, service, component, message, metadata)
  end

  defp normalize_metadata(metadata) when is_map(metadata) do
    Map.new(metadata, fn
      {key, value} when is_atom(key) -> {key, value}
      {key, value} when is_binary(key) ->
        {to_atom(key), value}
    end)
  end

  defp normalize_metadata(_), do: %{}

  defp enrich_metadata(metadata, service, component) do
    # System tags from service + component segments
    system_tags = [service | extract_segments(component)]

    # User tags from structured metadata fields
    tags =
      []
      |> add_tag_if(metadata[:call_type], "call_type")
      |> add_tag_if(metadata[:status], "status")
      |> add_tag_if(metadata[:action], "action")
      |> add_tag_if(metadata[:error_type], "error_type")
      |> add_tag_if(metadata[:agent_name], "agent")

    # Forward any existing tags from the source
    existing_tags = List.wrap(metadata[:tags] || metadata["tags"])
    existing_sys = List.wrap(metadata[:system_tags] || metadata["system_tags"])

    metadata
    |> Map.put(:system_tags, Enum.uniq(system_tags ++ existing_sys))
    |> Map.put(:tags, Enum.uniq(tags ++ existing_tags))
  end

  defp extract_segments(component) when is_binary(component) do
    component
    |> String.split(~r{[/:.\s]})
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.downcase/1)
    |> Enum.flat_map(fn seg -> [seg, "module:#{seg}"] end)
  end

  defp extract_segments(_), do: []

  defp add_tag_if(list, nil, _prefix), do: list

  defp add_tag_if(list, value, prefix) when is_binary(value) do
    ["#{prefix}:#{String.downcase(value)}" | list]
  end

  defp add_tag_if(list, value, prefix) do
    ["#{prefix}:#{String.downcase(to_string(value))}" | list]
  end

  # Converts string key to atom safely - uses existing atom if available,
  # falls back to creating atom for known/safe keys only
  defp to_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end
  defp to_atom(key), do: key

  defp parse_log_level(level) when is_binary(level) do
    case String.downcase(level) do
      "debug" -> :debug
      "info" -> :info
      "warn" -> :warning
      "warning" -> :warning
      "error" -> :error
      _ -> :info
    end
  end

  defp parse_log_level(level) when is_atom(level), do: level
  defp parse_log_level(_), do: :info
end
