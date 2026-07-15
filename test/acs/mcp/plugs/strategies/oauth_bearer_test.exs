defmodule Acs.MCP.Plugs.Strategies.OAuthBearerTest do
  use ExUnit.Case, async: true

  alias Acs.MCP.Plugs.Strategies.OAuthBearer

  @org_claim "https://stewardacs.xyz/org"

  test "verified OAuth claims carry the user org and MCP permission" do
    claims = %{
      @org_claim => "acme",
      "permissions" => ["mcp:tools"],
      "email" => "user@example.test"
    }

    assert {:ok, result} = OAuthBearer.from_verified_claims(claims)
    assert result.org_id == "acme"
    assert result.role == "collaborator"
    assert result.permissions == ["mcp:tools"]
    assert result.agent_identity == "user@example.test"
  end

  test "mcp admin claim maps to admin" do
    claims = %{@org_claim => "acme", "scope" => "openid mcp:admin"}

    assert {:ok, %{org_id: "acme", role: "admin"}} =
             OAuthBearer.from_verified_claims(claims)
  end

  test "missing org claim fails closed" do
    assert {:error, "OAuth token has no organization claim"} =
             OAuthBearer.from_verified_claims(%{"permissions" => ["mcp:tools"]})
  end

  test "missing MCP grant fails closed" do
    assert {:error, "OAuth token lacks required MCP permission"} =
             OAuthBearer.from_verified_claims(%{
               @org_claim => "acme",
               "scope" => "openid profile"
             })
  end
end
