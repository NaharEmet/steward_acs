defmodule Acs.MCP.ClientSessionTest do
  use ExUnit.Case, async: false

  alias Acs.MCP.ClientSession

  test "URL-seeded audience wins over coding clientInfo" do
    ClientSession.seed_url_audience("sess_chat", :chat)

    ClientSession.bind("sess_chat", fn ->
      assert ClientSession.current_id() == "sess_chat"

      assert ClientSession.remember_initialize(
               %{"clientInfo" => %{"name" => "cursor"}},
               "agent-a"
             ) == :chat

      assert {:ok, %{audience: :chat, audience_source: :url}} =
               ClientSession.fetch("sess_chat")

      assert ClientSession.resolve_audience("agent-a") == :chat
    end)

    assert ClientSession.current_id() == nil
  end

  test "Claude clientInfo resolves to chat without URL seed" do
    ClientSession.bind("sess_claude", fn ->
      assert ClientSession.remember_initialize(
               %{"clientInfo" => %{"name" => "Claude"}},
               nil
             ) == :chat

      assert ClientSession.resolve_audience(nil) == :chat
    end)
  end

  test "coding clientInfo resolves to coding without URL seed" do
    ClientSession.bind("sess_coding", fn ->
      assert ClientSession.remember_initialize(
               %{"clientInfo" => %{"name" => "cursor"}},
               nil
             ) == :coding

      assert ClientSession.resolve_audience(nil) == :coding
    end)
  end

  test "seed_mcp_connect stores endpoint for provenance" do
    ClientSession.bind("sess_endpoint", fn ->
      :ok = ClientSession.seed_mcp_connect("sess_endpoint", "/mcp/chat/sse", :chat)

      assert ClientSession.resolve_mcp_endpoint(nil) == "/mcp/chat/sse"

      ClientSession.remember_initialize(
        %{"clientInfo" => %{"name" => "cursor"}},
        "agent-b"
      )

      assert ClientSession.resolve_mcp_endpoint("agent-b") == "/mcp/chat/sse"
      assert {:ok, %{mcp_endpoint: "/mcp/chat/sse"}} = ClientSession.fetch("sess_endpoint")
    end)
  end

  test "get_or_assign_agent_name sticks a pool name to the session" do
    session_id = "sess_pool_#{System.unique_integer([:positive])}"

    ClientSession.bind(session_id, fn ->
      name1 = ClientSession.get_or_assign_agent_name()
      name2 = ClientSession.get_or_assign_agent_name()

      assert is_binary(name1)
      assert name1 != ""
      assert name1 != "unknown"
      assert name2 == name1
    end)
  end
end
