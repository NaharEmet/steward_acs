defmodule Acs.MCP.Plugs.MCPAuthTest do
  use Acs.DataCase, async: false

  alias Acs.MCP.Plugs.MCPAuth
  alias Acs.Developers

  describe "call/2" do
    test "sets agent_cluster and role on request with valid developer key" do
      {:ok, %{key: raw_key}} = Developers.generate_key("mcp-auth-test", cluster: "dev")

      conn = %Plug.Conn{
        host: "localhost",
        method: "GET",
        request_path: "/mcp/v1/messages",
        remote_ip: {127, 0, 0, 1},
        req_headers: [{"x-api-key", raw_key}],
        query_params: %{},
        assigns: %{}
      }

      result = MCPAuth.call(conn, [])
      assert result.assigns.agent_role == "admin"
      assert result.assigns.agent_cluster == Acs.Cluster.current()
      assert result.assigns.agent_org_id == "dev"
    end

    test "skips auth for log ingestion endpoint" do
      conn = %Plug.Conn{
        host: "localhost",
        method: "POST",
        request_path: "/api/logs/ingest",
        remote_ip: {127, 0, 0, 1},
        req_headers: [],
        query_params: %{},
        assigns: %{}
      }

      result = MCPAuth.call(conn, [])
      assert result.assigns.agent_role == "admin"
      assert result.assigns.agent_cluster == Acs.Cluster.current()
    end

    test "extracts api_key from query params" do
      {:ok, %{key: raw_key}} = Developers.generate_key("query-auth-test", cluster: "staging")

      conn = %Plug.Conn{
        host: "localhost",
        method: "GET",
        request_path: "/mcp/v1/messages",
        remote_ip: {127, 0, 0, 1},
        req_headers: [],
        query_params: %{"api_key" => raw_key},
        assigns: %{}
      }

      result = MCPAuth.call(conn, [])
      assert result.assigns.agent_role == "admin"
      assert result.assigns.agent_org_id == "staging"
    end
  end
end
