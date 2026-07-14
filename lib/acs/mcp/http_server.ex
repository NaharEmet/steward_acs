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

  @max_log_batch 500
  @max_body_size 2_000_000
  @default_http_sleep_max_ms 300_000

  plug(:match)
  plug(Acs.MCP.Plugs.RateLimit)
  plug(Acs.MCP.Plugs.MCPAuth)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason, length: @max_body_size)
  plug(:dispatch)

  # MCP SSE endpoint — establishes a Server-Sent Events stream per MCP Streamable HTTP
  get "/mcp/sse" do
    conn = fetch_query_params(conn)
    session_id = generate_sse_session_id()

    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    case chunk(
           conn,
           "event: endpoint\ndata: /mcp/messages?session_id=#{session_id}\n\n"
         ) do
      {:ok, conn} ->
        :ok = Acs.MCP.SSESessionManager.register(session_id, self())
        sse_loop(conn, session_id)

      {:error, _reason} ->
        handle_sse_close(session_id, conn)
    end
  end

  # MCP Streamable HTTP messages endpoint — receives JSON-RPC and responds via SSE
  post "/mcp/messages" do
    conn = fetch_query_params(conn)
    session_id = conn.query_params["session_id"]

    if session_id && Acs.MCP.SSESessionManager.alive?(session_id) do
      handle_mcp_message(conn, session_id)
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(400, Jason.encode!(%{error: "Invalid or missing session_id"}))
      |> halt()
    end
  end

  # MCP Endpoints
  post "/mcp/v1/messages" do
    conn = fetch_query_params(conn)
    session_id = conn.query_params["session_id"] || generate_session_id()

    Logger.debug("MCP HTTP: received request on #{conn.request_path}")

    case conn.body_params do
      %{} = params ->
        case Protocol.handle_message(
               params,
               conn.assigns[:agent_role],
               conn.assigns[:agent_org_id],
               conn.assigns[:agent_permissions],
               conn.assigns[:agent_allowed_teams],
               conn.assigns[:agent_allowed_projects],
               conn.assigns[:agent_identity]
             ) do
          {:sleep, id, agent_id, timeout} ->
            timeout = cap_sleep_timeout(timeout)

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

                {:error, _reason} ->
                  Protocol.success_response(id, %{
                    "content" => [%{"type" => "text", "text" => "Error during sleep"}],
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
        if length(logs) > @max_log_batch do
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(413, Jason.encode!(%{error: "Batch too large (max #{@max_log_batch})"}))
        else
          results = Enum.map(logs, &process_log_entry/1)
          success_count = Enum.count(results, &(&1 == :ok))

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            200,
            Jason.encode!(%{status: "ok", stored: success_count, total: length(logs)})
          )
        end

      %{} = log_entry when map_size(log_entry) > 0 ->
        case process_log_entry(log_entry) do
          :ok ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(%{status: "ok"}))

          {:error, _reason} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(
              500,
              Jason.encode!(%{status: "error", reason: "Failed to store log entry"})
            )
        end

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          400,
          Jason.encode!(%{
            error:
              "Invalid log entry. Expected JSON with 'message' and optional 'level', 'service', 'component', 'metadata'"
          })
        )
    end
  end

  # Log query endpoint for external services
  get "/api/logs" do
    conn = fetch_query_params(conn)

    unless conn.assigns[:agent_role] in ~w(admin service) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        403,
        Jason.encode!(%{error: "Access denied: log query requires admin or service role"})
      )
      |> halt()
    end

    params = conn.query_params

    opts = [org: conn.assigns[:agent_org_id]]

    opts =
      case params["level"] do
        nil ->
          opts

        level ->
          case parse_log_level(level) do
            {:ok, atom} ->
              Keyword.put(opts, :level, atom)

            :error ->
              conn
              |> put_resp_content_type("application/json")
              |> send_resp(
                400,
                Jason.encode!(%{
                  error: "Invalid level: must be one of debug, info, warning, error"
                })
              )
              |> halt()
          end
      end

    opts =
      if params["limit"] do
        case Integer.parse(params["limit"]) do
          {n, ""} when n > 0 ->
            Keyword.put(opts, :limit, n)

          _ ->
            conn
            |> send_resp(400, Jason.encode!(%{error: "Invalid limit: must be positive integer"}))
            |> halt()
        end
      else
        opts
      end

    opts =
      if params["component"], do: Keyword.put(opts, :component, params["component"]), else: opts

    opts = if params["search"], do: Keyword.put(opts, :search, params["search"]), else: opts
    opts = if params["service"], do: Keyword.put(opts, :service, params["service"]), else: opts

    opts =
      if params["workflow_id"],
        do: Keyword.put(opts, :workflow_id, params["workflow_id"]),
        else: opts

    opts =
      if params["execution_id"],
        do: Keyword.put(opts, :execution_id, params["execution_id"]),
        else: opts

    opts = if params["since"], do: Keyword.put(opts, :since, params["since"]), else: opts
    opts = if params["until"], do: Keyword.put(opts, :until, params["until"]), else: opts

    opts =
      if params["offset"] do
        case Integer.parse(params["offset"]) do
          {n, ""} when n >= 0 ->
            Keyword.put(opts, :offset, n)

          _ ->
            conn
            |> send_resp(
              400,
              Jason.encode!(%{error: "Invalid offset: must be non-negative integer"})
            )
            |> halt()
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

    unless conn.assigns[:agent_role] in ~w(admin service) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        403,
        Jason.encode!(%{error: "Access denied: log query requires admin or service role"})
      )
      |> halt()
    end

    entry_id =
      case Integer.parse(id) do
        {n, ""} ->
          n

        _ ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(400, Jason.encode!(%{error: "Invalid entry id: must be an integer"}))
          |> halt()
      end

    window_size =
      case conn.query_params["window_size"] do
        nil ->
          30

        ws ->
          case Integer.parse(ws) do
            {n, ""} when n > 0 ->
              n

            _ ->
              conn
              |> put_resp_content_type("application/json")
              |> send_resp(
                400,
                Jason.encode!(%{error: "Invalid window_size: must be positive integer"})
              )
              |> halt()
          end
      end

    result = LogStore.get_context_before(entry_id, window_size, conn.assigns[:agent_org_id])

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(result))
  end

  # Health check
  get "/mcp/health" do
    db_ok =
      case Ecto.Adapters.SQL.query(Acs.Repo, "SELECT 1", []) do
        {:ok, _} -> true
        _ -> false
      end

    status = if db_ok, do: "healthy", else: "degraded"
    http_status = if db_ok, do: 200, else: 503

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      http_status,
      Jason.encode!(%{
        status: status,
        database: db_ok,
        timestamp: DateTime.utc_now()
      })
    )
  end

  # Task API for external apps
  post "/api/tasks" do
    body = conn.body_params

    case body do
      %{"title" => title, "created_by_agent" => agent_id}
      when is_binary(title) and is_binary(agent_id) ->
        safe_body =
          body
          |> Map.drop(["org", "org_id", "cluster"])
          |> Map.put("org", conn.assigns[:agent_org_id])

        case Acs.create_task(safe_body, agent_id) do
          {:ok, task} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(201, Jason.encode!(%{status: "created", task_id: task.id, task: task}))

          {:warn, task, similar} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(
              201,
              Jason.encode!(%{
                status: "created_with_warning",
                task_id: task.id,
                task: task,
                similar_tasks: similar
              })
            )

          {:error, _reason} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(400, Jason.encode!(%{status: "error", reason: "Failed to create task"}))
        end

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          400,
          Jason.encode!(%{error: "Missing required fields: title, created_by_agent"})
        )
    end
  end

  # Bump/update a task
  patch "/api/tasks/:id" do
    body = conn.body_params

    case Acs.bump_task(id, body || %{}) do
      {:ok, task} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{status: "updated", task_id: task.id, event_count: task.event_count})
        )

      {:error, reason} ->
        status = if reason == :task_not_found, do: 404, else: 400

        message =
          if reason == :task_not_found, do: "Task not found", else: "Failed to update task"

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(%{status: "error", reason: message}))
    end
  end

  # Catch-all
  match _ do
    conn |> send_resp(404, ~s({"error": "Not found"}))
  end

  defp handle_mcp_message(conn, session_id) do
    case conn.body_params do
      %{} = params ->
        case Protocol.handle_message(
               params,
               conn.assigns[:agent_role],
               conn.assigns[:agent_org_id],
               conn.assigns[:agent_permissions],
               conn.assigns[:agent_allowed_teams],
               conn.assigns[:agent_allowed_projects],
               conn.assigns[:agent_identity]
             ) do
          {:sleep, id, agent_id, timeout} ->
            timeout = cap_sleep_timeout(timeout)

            Logger.info("MCP SSE: agent #{agent_id} sleeping (timeout=#{inspect(timeout)})")

            org = conn.assigns[:agent_org_id]

            Task.start(fn ->
              result =
                Acs.Org.with_current(org, fn ->
                  Acs.MCP.Tools.CoreHandlers.sleep_and_wait(agent_id, timeout)
                end)

              response =
                case result do
                  {:ok, data} ->
                    Protocol.success_response(id, %{
                      "content" => [
                        %{"type" => "text", "text" => Jason.encode!(data, pretty: true)}
                      ]
                    })

                  {:error, _reason} ->
                    Protocol.success_response(id, %{
                      "content" => [%{"type" => "text", "text" => "Error during sleep"}],
                      "isError" => true
                    })
                end

              Acs.MCP.SSESessionManager.send_response(session_id, response, org)
            end)

            conn |> send_resp(202, "")

          {:ok, response} ->
            Logger.debug("MCP SSE: response=#{inspect(response)}")
            Acs.MCP.SSESessionManager.send_response(session_id, response)
            conn |> send_resp(202, "")

          {:error, reason} ->
            error = Protocol.error_response(nil, -32700, "Parse error", reason)
            Acs.MCP.SSESessionManager.send_response(session_id, error)
            conn |> send_resp(202, "")
        end

      _ ->
        conn |> send_resp(400, ~s({"error": "Invalid JSON"}))
    end
  end

  defp generate_session_id do
    "http_#{System.system_time(:millisecond)}_#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
  end

  defp generate_sse_session_id do
    "sse_#{System.system_time(:millisecond)}_#{:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)}"
  end

  defp sse_loop(conn, session_id) do
    receive do
      {:send_response, response} ->
        case chunk(conn, "event: message\ndata: #{Jason.encode!(response)}\n\n") do
          {:ok, conn} -> sse_loop(conn, session_id)
          {:error, _reason} -> handle_sse_close(session_id, conn)
        end

      {:send_event, event, data} ->
        case chunk(conn, "event: #{event}\ndata: #{data}\n\n") do
          {:ok, conn} -> sse_loop(conn, session_id)
          {:error, _reason} -> handle_sse_close(session_id, conn)
        end

      :close ->
        Acs.MCP.SSESessionManager.unregister(session_id)
        conn
    after
      30_000 ->
        case chunk(conn, ": heartbeat\n\n") do
          {:ok, conn} -> sse_loop(conn, session_id)
          {:error, _reason} -> handle_sse_close(session_id, conn)
        end
    end
  end

  defp handle_sse_close(session_id, conn) do
    Acs.MCP.SSESessionManager.unregister(session_id)
    conn
  end

  defp cap_sleep_timeout(:infinity), do: http_sleep_max_ms()

  defp cap_sleep_timeout(timeout) when is_integer(timeout) and timeout > 0,
    do: min(timeout, http_sleep_max_ms())

  defp cap_sleep_timeout(_), do: http_sleep_max_ms()

  defp http_sleep_max_ms do
    Application.get_env(:steward_acs, :http_sleep_max_ms, @default_http_sleep_max_ms)
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
      |> Map.put(:org, Acs.Org.current())

    LogStore.store_log(level, service, component, message, metadata)
  end

  defp normalize_metadata(metadata) when is_map(metadata) do
    Map.new(metadata, fn
      {key, value} when is_atom(key) ->
        {key, value}

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
      "debug" -> {:ok, :debug}
      "info" -> {:ok, :info}
      "warn" -> {:ok, :warning}
      "warning" -> {:ok, :warning}
      "error" -> {:ok, :error}
      _ -> :error
    end
  end
end
