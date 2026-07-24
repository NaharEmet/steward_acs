defmodule Acs.MCP.OAuth.DCRTest do
  use ExUnit.Case, async: false

  setup do
    previous = Application.get_env(:steward_acs, :oauth_fixed_dcr_client_id)

    on_exit(fn ->
      if previous do
        Application.put_env(:steward_acs, :oauth_fixed_dcr_client_id, previous)
      else
        Application.delete_env(:steward_acs, :oauth_fixed_dcr_client_id)
      end
    end)

    :ok
  end

  test "returns the fixed client id when configured" do
    Application.put_env(:steward_acs, :oauth_fixed_dcr_client_id, "fixed_claude_client")

    conn =
      Plug.Test.conn(
        :post,
        "/oidc/register",
        Jason.encode!(%{
          "client_name" => "Claude",
          "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"]
        })
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
      |> Acs.MCP.OAuth.DCR.call([])

    assert conn.status == 201
    body = Jason.decode!(conn.resp_body)
    assert body["client_id"] == "fixed_claude_client"
  end

  test "returns 503 when fixed client is missing" do
    Application.delete_env(:steward_acs, :oauth_fixed_dcr_client_id)

    conn =
      Plug.Test.conn(:post, "/oidc/register", "{}")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
      |> Acs.MCP.OAuth.DCR.call([])

    assert conn.status == 503
  end
end
