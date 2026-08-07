defmodule Acs.MCP.OAuth.CaddyfileIssuerTest do
  use ExUnit.Case, async: true

  @caddyfile "Caddyfile.multitenant"

  test "authorization-server metadata issuer is host-based, not the Auth0 domain" do
    content = File.read!(@caddyfile)

    assert content =~ "oauth_routes"
    assert content =~ ~s("issuer":"https://{host}/")
    refute content =~ ~s("issuer":"https://{$AUTH0_DOMAIN}/")
  end

  test "jwks_uri still points at the Auth0 domain (keys live there)" do
    content = File.read!(@caddyfile)
    assert content =~ ~s("jwks_uri":"https://{$AUTH0_DOMAIN}/.well-known/jwks.json")
  end
end
