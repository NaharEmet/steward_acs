defmodule Acs.MCP.AudienceTest do
  use ExUnit.Case, async: true

  alias Acs.MCP.Audience

  describe "from_client_name/1" do
    test "detects coding agents" do
      assert Audience.from_client_name("cursor-vscode") == :coding
      assert Audience.from_client_name("Claude Code") == :coding
      assert Audience.from_client_name("opencode") == :coding
    end

    test "detects chat assistants" do
      assert Audience.from_client_name("claude.ai") == :chat
      assert Audience.from_client_name("ChatGPT") == :chat
      assert Audience.from_client_name("Claude") == :chat
      assert Audience.from_client_name("claude-desktop") == :chat
    end
  end

  describe "from_args/1" do
    test "explicit audience wins" do
      assert Audience.from_args(%{"audience" => "chat", "_auth_audience" => "coding"}) == :chat
      assert Audience.from_args(%{"mode" => "knowledge"}) == :chat
      assert Audience.from_args(%{"mode" => "mcp"}) == :coding
    end

    test "falls back to _auth_audience" do
      assert Audience.from_args(%{"_auth_audience" => "chat"}) == :chat
    end
  end

  describe "to_guidance_mode/1" do
    test "maps audiences to legacy modes" do
      assert Audience.to_guidance_mode(:chat) == :knowledge
      assert Audience.to_guidance_mode(:coding) == :mcp
    end
  end
end
