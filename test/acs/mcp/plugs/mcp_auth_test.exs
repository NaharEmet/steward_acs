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

    test "does not accept api_key from query params" do
      {:ok, %{key: raw_key}} = Developers.generate_key("query-auth-test", cluster: "staging")

      conn =
        Plug.Test.conn(:get, "/mcp/v1/messages", %{"api_key" => raw_key})

      assert %Plug.Conn{halted: true, status: 401} = MCPAuth.call(conn, [])
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
  end
end
