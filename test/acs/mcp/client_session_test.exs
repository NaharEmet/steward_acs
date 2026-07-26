defmodule Acs.MCP.ClientSessionTest do
  use ExUnit.Case, async: false

  alias Acs.MCP.ClientSession

  test "bind exposes current session id and stores initialize audience" do
    ClientSession.bind("sess_test_1", fn ->
      assert ClientSession.current_id() == "sess_test_1"

      audience =
        ClientSession.remember_initialize(
          %{"clientInfo" => %{"name" => "claude.ai", "version" => "1"}},
          "agent-a"
        )

      assert audience == :chat
      assert {:ok, %{audience: :chat}} = ClientSession.fetch("sess_test_1")
      assert {:ok, %{audience: :chat}} = ClientSession.fetch({:agent, "agent-a"})
      assert ClientSession.resolve_audience("agent-a") == :chat
    end)

    assert ClientSession.current_id() == nil
  end

  test "coding clientInfo resolves to coding" do
    ClientSession.bind("sess_test_2", fn ->
      assert ClientSession.remember_initialize(
               %{"clientInfo" => %{"name" => "cursor"}},
               nil
             ) == :coding

      assert ClientSession.resolve_audience(nil) == :coding
    end)
  end
end
