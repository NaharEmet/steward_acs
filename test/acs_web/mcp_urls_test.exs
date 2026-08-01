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

  test "chat_system_prompt loads Always Active instructions" do
    prompt = McpUrls.chat_system_prompt()

    assert prompt =~ "Steward ACS — Always Active"
    assert prompt =~ "always-loaded"
    assert prompt =~ "Never use find tools or `tool_search`"
    assert prompt =~ "`steward_ask`"
    assert prompt =~ "`steward_write`"
    assert prompt =~ "`steward_work`"
    refute prompt =~ "`get_started`"
  end

  test "coding_system_prompt loads AGENTS_STEWARD instructions" do
    prompt = McpUrls.coding_system_prompt()

    assert prompt =~ "Steward ACS — Agent Instructions"
    assert prompt =~ "get_present_status"
    assert prompt =~ "create_work"
  end
end
