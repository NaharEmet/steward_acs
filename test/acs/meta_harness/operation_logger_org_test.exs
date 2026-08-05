defmodule Acs.MetaHarness.OperationLoggerOrgTest do
  use Acs.DataCase, async: false

  alias Acs.MetaHarness.OperationLogger
  alias Acs.MetaHarness.SQL
  alias Acs.Observability.AgentOps

  @tool "meta_harness_org_test"

  setup do
    pid =
      if Process.whereis(OperationLogger) do
        Process.whereis(OperationLogger)
      else
        start_supervised!(OperationLogger)
      end

    Ecto.Adapters.SQL.Sandbox.allow(Acs.Repo, self(), pid)
    delete_test_rows()
    :ok
  end

  test "flush persists org from log_async opts" do
    assert :ok =
             OperationLogger.log_async(@tool, :success, 10, nil, nil, "agent", nil, org: "acme")

    assert :ok = OperationLogger.flush()
    assert fetch_org(@tool) == "acme"
    delete_test_rows()
  end

  test "AgentOps.log_tool passes org through to INSERT" do
    assert :ok =
             AgentOps.log_tool(
               tool_name: @tool,
               result: :ok,
               latency_ms: 5,
               org: "tenant-b"
             )

    assert :ok = OperationLogger.flush()
    assert fetch_org(@tool) == "tenant-b"
    delete_test_rows()
  end

  defp fetch_org(tool_name) do
    {:ok, %{rows: [[org]]}} =
      Ecto.Adapters.SQL.query(
        Repo,
        SQL.adapt("SELECT org FROM acs_tool_operations WHERE tool_name = ?1 LIMIT 1"),
        [tool_name]
      )

    org
  end

  defp delete_test_rows do
    Ecto.Adapters.SQL.query!(
      Repo,
      SQL.adapt("DELETE FROM acs_tool_operations WHERE tool_name = ?1"),
      [@tool]
    )
  end
end
