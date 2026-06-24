defmodule Acs.MCP.Plugs.MCPAuth do
  @moduledoc """
  Authentication plug for the ACS MCP HTTP server.

  Uses a configurable chain of authentication strategies.
  Strategies are defined in `:auth_strategies` config key (list of module names).
  Default: `[Acs.MCP.Plugs.Strategies.Developer, Acs.MCP.Plugs.Strategies.Default]`

  Each strategy is tried in order until one returns `{:ok, ...}`.
  If all fail, returns 401.

  Skips auth for `/api/logs/ingest` (uses its own auth).

  Sets `conn.assigns.agent_role`, `conn.assigns.agent_org_id`,
  `conn.assigns.agent_cluster`, and `conn.assigns.agent_permissions` on success.
  """
  import Plug.Conn
  require Logger

  @default_strategies [Acs.MCP.Plugs.Strategies.Developer, Acs.MCP.Plugs.Strategies.Default]

  def init(opts), do: opts

  def call(conn, _opts) do
    # Skip authentication for log ingestion endpoint — it uses its own auth
    if String.starts_with?(conn.request_path, "/api/logs/ingest") do
      conn
      |> assign(:agent_role, "admin")
      |> assign(:agent_org_id, nil)
      |> assign(:agent_cluster, Acs.Cluster.current())
      |> assign(:agent_permissions, nil)
    else
      conn = fetch_query_params(conn)
      key = extract_key(conn)
      strategies = auth_strategies()

      case authenticate_with_strategies(key, conn, strategies) do
        {:ok, result} ->
          conn
          |> assign(:agent_role, result.role)
          |> assign(:agent_org_id, result.org_id)
          |> assign(:agent_cluster, Acs.Cluster.current())
          |> assign(:agent_permissions, result.permissions)

        {:error, reason} ->
          unauthorized(conn, reason)
      end
    end
  end

  defp extract_key(conn) do
    case get_req_header(conn, "x-api-key") do
      [key | _] when is_binary(key) and key != "" -> key
      _ -> conn.query_params["api_key"]
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

  defp unauthorized(conn, reason) do
    body = Jason.encode!(%{error: reason})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, body)
    |> halt()
  end
end
