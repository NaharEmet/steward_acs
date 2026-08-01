defmodule Acs.MCP.HTTPServerStreamableTest do
  use Acs.DataCase, async: false

  alias Acs.Developers
  alias Acs.MCP.HTTPServer

  test "POST /mcp/chat/sse accepts Streamable HTTP JSON-RPC (not 404)" do
    {:ok, %{key: raw_key}} =
      Developers.generate_key("streamable-chat-test", role: "admin", org: "dev")

    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2024-11-05",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "0.0.1"}
        }
      })

    conn =
      Plug.Test.conn(:post, "/mcp/chat/sse", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-api-key", raw_key)
      |> HTTPServer.call([])

    refute conn.status == 404
    assert conn.status in [200, 202]
    assert get_resp_header(conn, "content-type") |> List.first() =~ "application/json"
  end

  defp get_resp_header(conn, key), do: Plug.Conn.get_resp_header(conn, key)
end
