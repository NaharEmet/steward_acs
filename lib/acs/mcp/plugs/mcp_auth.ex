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
  `conn.assigns.agent_permissions`, and
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
        conn = fetch_query_params(conn)
        key = extract_key(conn)
        strategies = auth_strategies()

        case authenticate_with_strategies(key, conn, strategies) do
          {:ok, result} ->
            with {:ok, org_id} <- Acs.Org.resolve_active_org(result.org_id),
                 :ok <- Acs.Org.validate_hint(org_id, conn.assigns[:org_hint]) do
              :ok = Acs.Org.put_current(org_id)

              conn
              |> assign(:current_org, org_id)
              |> assign(:agent_role, result.role)
              |> assign(:agent_org_id, org_id)
              |> assign(:agent_permissions, result.permissions)
              |> assign(:agent_allowed_teams, result[:allowed_teams])
              |> assign(:agent_allowed_projects, result[:allowed_projects])
              |> assign(:agent_identity, result[:agent_identity])
            else
              {:error, :org_hint_mismatch} ->
                unauthorized(conn, "Authenticated organization does not match request host")

              {:error, :missing_credential_org} ->
                unauthorized(conn, "Credential has no organization")
            end

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
        org_id = Acs.Org.configured()

        case Acs.Org.validate_hint(org_id, conn.assigns[:org_hint]) do
          :ok ->
            :ok = Acs.Org.put_current(org_id)

            conn
            |> assign(:current_org, org_id)
            |> assign(:agent_role, "service")
            |> assign(:agent_org_id, org_id)
            |> assign(:agent_permissions, nil)
            |> assign(:agent_identity, "service")

          {:error, :org_hint_mismatch} ->
            unauthorized(conn, "Authenticated organization does not match request host")
        end

      true ->
        unauthorized(conn, "Invalid log ingest key")
    end
  end

  defp health_check?(conn) do
    conn.method == "GET" and conn.request_path == "/mcp/health"
  end

  defp extract_key(conn) do
    conn
    |> header_api_key()
    |> case do
      key when is_binary(key) -> key
      _ -> bearer_api_key(conn) || query_api_key(conn)
    end
  end

  defp header_api_key(conn) do
    case get_req_header(conn, "x-api-key") do
      [key | _] when is_binary(key) and key != "" -> key
      _ -> nil
    end
  end

  defp bearer_api_key(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> key | _] when is_binary(key) and key != "" -> key
      _ -> nil
    end
  end

  defp query_api_key(conn) do
    if query_key_auth_enabled?() do
      case conn.query_params["api_key"] do
        key when is_binary(key) and key != "" -> key
        _ -> nil
      end
    else
      nil
    end
  end

  defp query_key_auth_enabled? do
    Application.get_env(:steward_acs, :mcp_query_key_auth, false)
  end

  defp auth_strategies do
    case Application.get_env(:steward_acs, :auth_strategies) do
      strategies when is_list(strategies) -> strategies
      _ -> @default_strategies
    end
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

    conn =
      conn
      |> maybe_put_oauth_challenge()
      |> put_resp_content_type("application/json")

    conn
    |> send_resp(401, body)
    |> halt()
  end

  defp maybe_put_oauth_challenge(conn) do
    alias Acs.MCP.OAuth.Config

    case {Config.enabled?(), Config.protected_resource_metadata_url(conn)} do
      {true, url} when is_binary(url) ->
        challenge = ~s(Bearer error="invalid_token", resource_metadata="#{url}")
        Plug.Conn.put_resp_header(conn, "www-authenticate", challenge)

      _ ->
        conn
    end
  end
end
