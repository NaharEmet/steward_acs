defmodule Acs.MCP.Plugs.MCPAuthTest do
  use Acs.DataCase, async: false

  alias Acs.MCP.Plugs.MCPAuth
  alias Acs.Developers

  describe "call/2" do
    test "sets agent_cluster and role on request with valid developer key" do
      {:ok, %{key: raw_key}} =
        Developers.generate_key("mcp-auth-test", role: "admin", cluster: "dev")

      conn =
        Plug.Test.conn(:get, "/mcp/v1/messages")
        |> Plug.Conn.put_req_header("x-api-key", raw_key)

      result = MCPAuth.call(conn, [])
      assert result.assigns.agent_role == "admin"
      assert result.assigns.agent_cluster == Acs.Cluster.current()
      assert result.assigns.agent_org_id == "dev"
    end

    test "requires log ingest key for ingestion endpoint" do
      conn = Plug.Test.conn(:post, "/api/logs/ingest")

      assert %Plug.Conn{halted: true, status: 401} = MCPAuth.call(conn, [])
    end

    test "authenticates log ingest with valid key" do
      conn =
        Plug.Test.conn(:post, "/api/logs/ingest")
        |> Plug.Conn.put_req_header("x-log-ingest-key", "test-log-ingest-key")

      result = MCPAuth.call(conn, [])
      assert result.assigns.agent_role == "service"
      assert result.assigns.agent_cluster == Acs.Cluster.current()
    end

    test "does not accept api_key from query params by default" do
      {:ok, %{key: raw_key}} = Developers.generate_key("query-auth-test", cluster: "staging")

      conn =
        Plug.Test.conn(:get, "/mcp/v1/messages", %{"api_key" => raw_key})

      assert %Plug.Conn{halted: true, status: 401} = MCPAuth.call(conn, [])
    end

    test "accepts api_key from query params when MCP_QUERY_KEY_AUTH is enabled" do
      original = Application.get_env(:steward_acs, :mcp_query_key_auth)
      Application.put_env(:steward_acs, :mcp_query_key_auth, true)

      on_exit(fn ->
        Application.put_env(:steward_acs, :mcp_query_key_auth, original)
      end)

      {:ok, %{key: raw_key}} =
        Developers.generate_key("query-auth-enabled-test", role: "admin", cluster: "dev")

      conn =
        Plug.Test.conn(:get, "/mcp/v1/messages", %{"api_key" => raw_key})

      result = MCPAuth.call(conn, [])
      assert result.assigns.agent_role == "admin"
      assert result.assigns.agent_org_id == "dev"
    end

    test "accepts Bearer token with developer key" do
      {:ok, %{key: raw_key}} =
        Developers.generate_key("bearer-auth-test", role: "admin", cluster: "dev")

      conn =
        Plug.Test.conn(:get, "/mcp/v1/messages")
        |> Plug.Conn.put_req_header("authorization", "Bearer #{raw_key}")

      result = MCPAuth.call(conn, [])
      assert result.assigns.agent_role == "admin"
      assert result.assigns.agent_org_id == "dev"
    end

    test "localhost fallback grants admin when enabled and no key provided" do
      original = Application.get_env(:steward_acs, :mcp_auth_local_fallback)
      Application.put_env(:steward_acs, :mcp_auth_local_fallback, true)

      on_exit(fn ->
        Application.put_env(:steward_acs, :mcp_auth_local_fallback, original)
      end)

      conn = Plug.Test.conn(:get, "/mcp/v1/messages")

      result = MCPAuth.call(conn, [])
      assert result.assigns.agent_role == "admin"
    end

    test "localhost fallback does not bypass invalid API key" do
      original = Application.get_env(:steward_acs, :mcp_auth_local_fallback)
      Application.put_env(:steward_acs, :mcp_auth_local_fallback, true)

      on_exit(fn ->
        Application.put_env(:steward_acs, :mcp_auth_local_fallback, original)
      end)

      conn =
        Plug.Test.conn(:get, "/mcp/v1/messages")
        |> Plug.Conn.put_req_header("x-api-key", "not-a-valid-key")

      assert %Plug.Conn{halted: true, status: 401} = MCPAuth.call(conn, [])
    end

    test "service API key authenticates with service role" do
      original = Application.get_env(:steward_acs, :service_api_key)
      Application.put_env(:steward_acs, :service_api_key, "test-service-key-12345")

      on_exit(fn ->
        Application.put_env(:steward_acs, :service_api_key, original)
      end)

      conn =
        Plug.Test.conn(:get, "/mcp/v1/messages")
        |> Plug.Conn.put_req_header("x-api-key", "test-service-key-12345")

      result = MCPAuth.call(conn, [])
      assert result.assigns.agent_role == "service"
      assert result.assigns.agent_identity == "service"
    end

    test "returns WWW-Authenticate challenge when OAuth is enabled" do
      original = %{
        oauth: Application.get_env(:steward_acs, :oauth_bearer_enabled),
        domain: Application.get_env(:steward_acs, :auth0_domain),
        audience: Application.get_env(:steward_acs, :auth0_audience),
        public: Application.get_env(:steward_acs, :mcp_public_url),
        resource: Application.get_env(:steward_acs, :mcp_resource_url),
        strategies: Application.get_env(:steward_acs, :auth_strategies)
      }

      Application.put_env(:steward_acs, :oauth_bearer_enabled, true)
      Application.put_env(:steward_acs, :auth0_domain, "dev-jw5wgp2b.us.auth0.com")
      Application.put_env(:steward_acs, :auth0_audience, "https://prod.stewardacs.xyz/mcp/sse")
      Application.put_env(:steward_acs, :mcp_public_url, "https://prod.stewardacs.xyz")
      Application.put_env(:steward_acs, :mcp_resource_url, "https://prod.stewardacs.xyz/mcp/sse")

      Application.put_env(:steward_acs, :auth_strategies, [
        Acs.MCP.Plugs.Strategies.Developer,
        Acs.MCP.Plugs.Strategies.OAuthBearer,
        Acs.MCP.Plugs.Strategies.Default
      ])

      on_exit(fn ->
        Application.put_env(:steward_acs, :oauth_bearer_enabled, original.oauth)
        Application.put_env(:steward_acs, :auth0_domain, original.domain)
        Application.put_env(:steward_acs, :auth0_audience, original.audience)
        Application.put_env(:steward_acs, :mcp_public_url, original.public)
        Application.put_env(:steward_acs, :mcp_resource_url, original.resource)
        Application.put_env(:steward_acs, :auth_strategies, original.strategies)
      end)

      conn = Plug.Test.conn(:get, "/mcp/v1/messages")

      result = MCPAuth.call(conn, [])

      assert result.status == 401
      assert {"www-authenticate", challenge} = List.keyfind(result.resp_headers, "www-authenticate", 0)
      assert challenge =~ "resource_metadata="
      assert challenge =~ "/.well-known/oauth-protected-resource/mcp/sse"
    end
  end
end
