defmodule Acs.MCP.OAuth.ConfigTest do
  use ExUnit.Case, async: true

  alias Acs.MCP.OAuth.Config

  test "assert_runtime_allowed! raises when OAuth is on in single-tenant mode" do
    assert_raise RuntimeError, ~r/not supported in single-tenant mode/, fn ->
      Config.assert_runtime_allowed!(true, false)
    end
  end

  test "assert_runtime_allowed! allows OAuth only with multi-tenant" do
    assert :ok = Config.assert_runtime_allowed!(true, true)
    assert :ok = Config.assert_runtime_allowed!(false, false)
    assert :ok = Config.assert_runtime_allowed!(false, true)
  end

  test "resource_url_for_host is the canonical /mcp/sse Auth0 API identifier" do
    assert Config.resource_url_for_host("anantha.stewardacs.xyz") ==
             "https://anantha.stewardacs.xyz/mcp/sse"
  end

  test "accepted_resource_urls accepts the canonical resource for a /mcp/coding/sse connect URL" do
    accepted =
      Config.accepted_resource_urls("https://anantha.stewardacs.xyz/mcp/coding/sse")

    assert "https://anantha.stewardacs.xyz/mcp/sse" in accepted
    assert "https://anantha.stewardacs.xyz/mcp/chat/sse" in accepted
    assert "https://anantha.stewardacs.xyz/mcp/coding/sse" in accepted
    assert length(accepted) == length(Enum.uniq(accepted))
  end
end
