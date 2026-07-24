defmodule Acs.MCP.BridgeSessionStoreTest do
  use ExUnit.Case, async: false

  alias Acs.MCP.BridgeSessionStore

  test "sessions persist across caller processes" do
    session_id = "bridge-session-#{System.unique_integer([:positive])}"
    session = %{api_key: "test-key", org_id: "org-a"}

    task = Task.async(fn -> BridgeSessionStore.put(session_id, session) end)
    assert Task.await(task) == :ok

    assert {:ok, stored} = BridgeSessionStore.fetch(session_id)
    assert stored.api_key == "test-key"
    assert stored.org_id == "org-a"
    assert is_integer(stored.inserted_at)
  end
end
