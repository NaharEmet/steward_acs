defmodule Acs.MCP.SSESessionManagerTest do
  use ExUnit.Case, async: false

  alias Acs.MCP.SSESessionManager

  test "unregistering one session preserves the manager and other sessions" do
    org = "sse-session-manager-test"
    session_id = "session-#{System.unique_integer([:positive])}"
    other_session_id = "session-#{System.unique_integer([:positive])}"

    first =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    second =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn ->
      SSESessionManager.unregister(session_id, org)
      SSESessionManager.unregister(other_session_id, org)
      Process.exit(first, :kill)
      Process.exit(second, :kill)
    end)

    SSESessionManager.register(session_id, first, org)
    SSESessionManager.register(other_session_id, second, org)
    assert SSESessionManager.alive?(session_id, org)
    assert SSESessionManager.alive?(other_session_id, org)

    SSESessionManager.unregister(session_id, org)

    refute SSESessionManager.alive?(session_id, org)
    assert SSESessionManager.alive?(other_session_id, org)
    assert Process.alive?(Process.whereis(SSESessionManager))
  end

  test "replacing a session demonitor its previous process" do
    org = "sse-session-manager-test"
    session_id = "session-#{System.unique_integer([:positive])}"

    first =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    second =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn ->
      SSESessionManager.unregister(session_id, org)
      Process.exit(first, :kill)
      Process.exit(second, :kill)
    end)

    SSESessionManager.register(session_id, first, org)
    SSESessionManager.register(session_id, second, org)
    assert SSESessionManager.alive?(session_id, org)

    {:monitors, monitors} = Process.info(Process.whereis(SSESessionManager), :monitors)
    refute {:process, first} in monitors
    assert {:process, second} in monitors
  end
end
