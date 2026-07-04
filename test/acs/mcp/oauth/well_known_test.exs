defmodule Acs.MCP.OAuth.WellKnownTest do
  use ExUnit.Case, async: true

  alias Acs.MCP.OAuth.{Config, WellKnown}

  setup do
    original = %{
      oauth: Application.get_env(:steward_acs, :oauth_bearer_enabled),
      domain: Application.get_env(:steward_acs, :auth0_domain),
      audience: Application.get_env(:steward_acs, :auth0_audience),
      public: Application.get_env(:steward_acs, :mcp_public_url),
      resource: Application.get_env(:steward_acs, :mcp_resource_url)
    }

    Application.put_env(:steward_acs, :oauth_bearer_enabled, true)
    Application.put_env(:steward_acs, :auth0_domain, "dev-jw5wgp2b.us.auth0.com")
    Application.put_env(:steward_acs, :auth0_audience, "https://prod.stewardacs.xyz/mcp/sse")
    Application.put_env(:steward_acs, :mcp_public_url, "https://prod.stewardacs.xyz")
    Application.put_env(:steward_acs, :mcp_resource_url, "https://prod.stewardacs.xyz/mcp/sse")

    on_exit(fn ->
      Application.put_env(:steward_acs, :oauth_bearer_enabled, original.oauth)
      Application.put_env(:steward_acs, :auth0_domain, original.domain)
      Application.put_env(:steward_acs, :auth0_audience, original.audience)
      Application.put_env(:steward_acs, :mcp_public_url, original.public)
      Application.put_env(:steward_acs, :mcp_resource_url, original.resource)
    end)

    :ok
  end

  test "serves protected resource metadata for MCP path" do
    conn =
      :get
      |> Plug.Test.conn(Config.protected_resource_metadata_path())
      |> WellKnown.call([])

    assert conn.status == 200
    assert {"content-type", "application/json; charset=utf-8"} in conn.resp_headers

    body = Jason.decode!(conn.resp_body)

    assert body["resource"] == "https://prod.stewardacs.xyz/mcp/sse"
    assert body["authorization_servers"] == ["https://dev-jw5wgp2b.us.auth0.com/"]
    assert "header" in body["bearer_methods_supported"]
    assert "mcp:tools" in body["scopes_supported"]
  end

  test "returns 404 for unknown well-known path" do
    conn =
      :get
      |> Plug.Test.conn("/.well-known/oauth-protected-resource/other")
      |> WellKnown.call([])

    assert conn.status == 404
  end
end
