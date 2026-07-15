defmodule Acs.MCP.Plugs.MCPAuthTest do
  use Acs.DataCase, async: false

  alias Acs.MCP.Plugs.MCPAuth
  alias Acs.Developers

  defmodule OAuthResultStrategy do
    def authenticate("oauth-token", _conn) do
      {:ok,
       %{
         role: "collaborator",
         org_id: "oauth-org",
         permissions: ["mcp:tools"],
         agent_identity: "oauth-user"
       }}
    end

    def authenticate(_, _conn), do: {:error, "invalid OAuth token"}
  end

  describe "call/2" do
    test "developer key owns org context on a neutral host" do
      {:ok, %{key: raw_key}} =
        Developers.generate_key("mcp-auth-test", role: "admin", org: "dev")

      conn =
        Plug.Test.conn(:get, "/mcp/v1/messages")
        |> Plug.Conn.put_req_header("x-api-key", raw_key)

      result = MCPAuth.call(conn, [])
      assert result.assigns.agent_role == "admin"
      assert result.assigns.agent_org_id == "dev"
      assert result.assigns.current_org == "dev"
      assert Acs.Org.current() == "dev"
      assert result.assigns.agent_permissions == nil
      refute Map.has_key?(result.assigns, :agent_cluster)
    end

    test "developer key accepts a matching host hint" do
      {:ok, %{key: raw_key}} = Developers.generate_key("matching-hint", org: "dev")

      conn =
        Plug.Test.conn(:get, "/mcp/v1/messages")
        |> Plug.Conn.put_req_header("x-api-key", raw_key)
        |> Plug.Conn.assign(:org_hint, "dev")

      assert MCPAuth.call(conn, []).assigns.current_org == "dev"
    end

    test "developer key rejects a mismatched host hint" do
      {:ok, %{key: raw_key}} = Developers.generate_key("mismatched-hint", org: "dev")

      conn =
        Plug.Test.conn(:get, "/mcp/v1/messages")
        |> Plug.Conn.put_req_header("x-api-key", raw_key)
        |> Plug.Conn.assign(:org_hint, "other")

      result = MCPAuth.call(conn, [])
      assert result.halted
      assert result.status == 401
      assert Jason.decode!(result.resp_body)["error"] =~ "does not match request host"
    end

    test "OAuth result owns org context on neutral and matching hosts" do
      with_auth_strategies([OAuthResultStrategy], fn ->
        neutral =
          Plug.Test.conn(:get, "/mcp/v1/messages")
          |> Plug.Conn.put_req_header("authorization", "Bearer oauth-token")
          |> MCPAuth.call([])

        assert neutral.assigns.current_org == "oauth-org"
        assert neutral.assigns.agent_org_id == "oauth-org"

        matching =
          Plug.Test.conn(:get, "/mcp/v1/messages")
          |> Plug.Conn.put_req_header("authorization", "Bearer oauth-token")
          |> Plug.Conn.assign(:org_hint, "oauth-org")
          |> MCPAuth.call([])

        assert matching.assigns.current_org == "oauth-org"
      end)
    end

    test "OAuth result rejects a mismatched host hint" do
      with_auth_strategies([OAuthResultStrategy], fn ->
        result =
          Plug.Test.conn(:get, "/mcp/v1/messages")
          |> Plug.Conn.put_req_header("authorization", "Bearer oauth-token")
          |> Plug.Conn.assign(:org_hint, "other")
          |> MCPAuth.call([])

        assert %{halted: true, status: 401} = result
      end)
    end

    test "configured MCP API key falls back to configured org" do
      original_key = Application.get_env(:steward_acs, :mcp_api_key)
      original_org = Application.get_env(:steward_acs, :org_name)
      Application.put_env(:steward_acs, :mcp_api_key, "configured-key")
      Application.put_env(:steward_acs, :org_name, "configured-org")

      on_exit(fn ->
        restore_env(:mcp_api_key, original_key)
        restore_env(:org_name, original_org)
      end)

      conn =
        Plug.Test.conn(:get, "/mcp/v1/messages")
        |> Plug.Conn.put_req_header("x-api-key", "configured-key")

      result = MCPAuth.call(conn, [])
      assert result.assigns.agent_org_id == "configured-org"
      assert result.assigns.current_org == "configured-org"
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
      assert result.assigns.agent_org_id == "default"
      assert result.assigns.current_org == "default"
      refute Map.has_key?(result.assigns, :agent_cluster)
    end

    test "log ingest rejects a mismatched host hint" do
      conn =
        Plug.Test.conn(:post, "/api/logs/ingest")
        |> Plug.Conn.put_req_header("x-log-ingest-key", "test-log-ingest-key")
        |> Plug.Conn.assign(:org_hint, "other")

      assert %{halted: true, status: 401} = MCPAuth.call(conn, [])
    end

    test "does not accept api_key from query params by default" do
      {:ok, %{key: raw_key}} = Developers.generate_key("query-auth-test", org: "staging")

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
        Developers.generate_key("query-auth-enabled-test", role: "admin", org: "dev")

      conn =
        Plug.Test.conn(:get, "/mcp/v1/messages", %{"api_key" => raw_key})

      result = MCPAuth.call(conn, [])
      assert result.assigns.agent_role == "admin"
      assert result.assigns.agent_org_id == "dev"
    end

    test "accepts Bearer token with developer key" do
      {:ok, %{key: raw_key}} =
        Developers.generate_key("bearer-auth-test", role: "admin", org: "dev")

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

      assert {"www-authenticate", challenge} =
               List.keyfind(result.resp_headers, "www-authenticate", 0)

      assert challenge =~ "resource_metadata="
      assert challenge =~ "/.well-known/oauth-protected-resource/mcp/sse"
    end
  end

  defp with_auth_strategies(strategies, fun) do
    original = Application.get_env(:steward_acs, :auth_strategies)
    Application.put_env(:steward_acs, :auth_strategies, strategies)

    try do
      fun.()
    after
      restore_env(:auth_strategies, original)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:steward_acs, key)
  defp restore_env(key, value), do: Application.put_env(:steward_acs, key, value)
end
