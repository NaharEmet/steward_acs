defmodule Acs.MetaHarness.AnalyzerPercentileTest do
  use Acs.DataCase, async: false

  alias Acs.MetaHarness.Analyzer
  alias Acs.MetaHarness.RecentOps
  alias Acs.MetaHarness.SQL

  @tool "meta_harness_pct_test"

  setup do
    RecentOps.setup()
    RecentOps.clear()
    delete_test_rows()
    :ok
  end

  test "p50 latency uses sorted values from SQL path" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    ph = SQL.placeholders(4)

    for latency <- [100, 1, 50] do
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        INSERT INTO acs_tool_operations (tool_name, status, latency_ms, created_at)
        VALUES (#{ph})
        """,
        [@tool, "success", latency, now]
      )
    end

    result = Analyzer.analyze(timeframe: :last_24_hours, ets_fallback: false)
    lat = Map.fetch!(result.latency_analysis, @tool)
    assert lat.p50_latency == 50

    delete_test_rows()
  end

  defp delete_test_rows do
    Ecto.Adapters.SQL.query!(
      Repo,
      SQL.adapt("DELETE FROM acs_tool_operations WHERE tool_name = ?1"),
      [@tool]
    )
  end
end
