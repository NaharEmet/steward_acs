defmodule AcsWeb.McpUrlsTest do
  use ExUnit.Case, async: true

  alias AcsWeb.McpUrls

  setup do
    original = Application.get_env(:steward_acs, :mcp_public_url)

    on_exit(fn ->
      Application.put_env(:steward_acs, :mcp_public_url, original)
    end)

    Application.put_env(:steward_acs, :mcp_public_url, "https://prod.stewardacs.xyz")
    :ok
  end

  test "symmetric coding and chat paths" do
    [coding, chat] = McpUrls.endpoints()

    assert coding.path == "/mcp/coding/sse"
    assert coding.url == "https://prod.stewardacs.xyz/mcp/coding/sse"

    assert chat.path == "/mcp/chat/sse"
    assert chat.url == "https://prod.stewardacs.xyz/mcp/chat/sse"
  end
end
