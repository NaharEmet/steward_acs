defmodule Acs.MCP.Plugs.MCPAuth do
  @moduledoc """
  Authentication plug for the ACS MCP HTTP server.

  Uses a configurable chain of authentication strategies.
  Strategies are defined in `:auth_strategies` config key (list of module names).
  Default: `[Acs.MCP.Plugs.Strategies.Developer, Acs.MCP.Plugs.Strategies.Default]`

  Each strategy is tried in order until one returns `{:ok, ...}`.
  If all fail, returns 401.

  Log ingestion (`/api/logs/ingest`) requires `X-Log-Ingest-Key` matching
  `:log_ingest_key` config.

  Sets `conn.assigns.agent_role`, `conn.assigns.agent_org_id`,
  `conn.assigns.agent_cluster`, `conn.assigns.agent_permissions`, and
  `conn.assigns.agent_identity` on success.
  """
  import Plug.Conn
  require Logger

  @default_strategies [
    Acs.MCP.Plugs.Strategies.Developer,
    Acs.MCP.Plugs.Strategies.Default
  ]

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      health_check?(conn) ->
        conn

      String.starts_with?(conn.request_path, "/api/logs/ingest") ->
        authenticate_log_ingest(conn)

      true ->
        key = extract_key(conn)
        strategies = auth_strategies()

        case authenticate_with_strategies(key, conn, strategies) do
          {:ok, result} ->
            conn
            |> assign(:agent_role, result.role)
            |> assign(:agent_org_id, result.org_id)
            |> assign(:agent_cluster, Acs.Cluster.current())
            |> assign(:agent_permissions, result.permissions)
            |> assign(:agent_allowed_teams, result[:allowed_teams])
            |> assign(:agent_allowed_projects, result[:allowed_projects])
            |> assign(:agent_identity, result[:agent_identity])

          {:error, reason} ->
            unauthorized(conn, reason)
        end
    end
  end

  defp authenticate_log_ingest(conn) do
    expected = Application.get_env(:steward_acs, :log_ingest_key)

    ingest_key =
      case get_req_header(conn, "x-log-ingest-key") do
        [key | _] when is_binary(key) and key != "" -> key
        _ -> nil
      end

    cond do
      is_nil(expected) or expected == "" ->
        unauthorized(conn, "Log ingest is not configured")

      is_nil(ingest_key) ->
        unauthorized(conn, "Missing X-Log-Ingest-Key header")

      secure_compare(ingest_key, expected) ->
        conn
        |> assign(:agent_role, "service")
        |> assign(:agent_org_id, nil)
        |> assign(:agent_cluster, Acs.Cluster.current())
        |> assign(:agent_permissions, nil)
        |> assign(:agent_identity, "service")

      true ->
        unauthorized(conn, "Invalid log ingest key")
    end
  end

  defp health_check?(conn) do
    conn.method == "GET" and conn.request_path == "/mcp/health"
  end

  defp extract_key(conn) do
    case get_req_header(conn, "x-api-key") do
      [key | _] when is_binary(key) and key != "" -> key
      _ -> nil
    end
  end

  defp auth_strategies do
    Application.get_env(:steward_acs, :auth_strategies, @default_strategies)
  end

  defp authenticate_with_strategies(_key, _conn, []) do
    {:error, "Missing or invalid API key"}
  end

  defp authenticate_with_strategies(key, conn, [strategy | rest]) do
    case strategy.authenticate(key, conn) do
      {:ok, result} -> {:ok, result}
      {:error, _reason} -> authenticate_with_strategies(key, conn, rest)
    end
  end

  defp secure_compare(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)
  end

  defp secure_compare(_, _), do: false

  defp unauthorized(conn, reason) do
    body = Jason.encode!(%{error: reason})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, body)
    |> halt()
  end
end
