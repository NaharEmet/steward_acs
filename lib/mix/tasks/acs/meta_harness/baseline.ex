defmodule Mix.Tasks.Acs.MetaHarness.Baseline do
  @moduledoc """
  Capture a snapshot of current error counts as a baseline.

  After deploying fixes, run this to mark the current state.
  Subsequent reports will include a "Since Baseline" section
  showing only errors that occurred after the baseline timestamp.

  ## Usage

      mix acs.meta_harness.baseline
      mix acs.meta_harness.baseline --reason "Fixed agent_has_other_task constraint"

  The baseline is saved to `metaanalysis/baseline.json`.
  """

  use Mix.Task

  require Logger

  @shortdoc "Capture baseline error snapshot after deploying fixes"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start", [])

    reason = parse_reason(args)
    now = DateTime.utc_now()

    errors = capture_error_counts()

    baseline = %{
      "set_at" => DateTime.to_iso8601(now),
      "reason" => reason,
      "error_snapshot" => errors
    }

    path = "metaanalysis/baseline.json"
    File.write!(path, Jason.encode!(baseline, pretty: true))

    Mix.Shell.IO.info("""
    ✅ Baseline set at #{DateTime.to_iso8601(now)}
       Reason: #{reason}
       Error clusters captured: #{length(errors)}
       Saved to: #{path}
    """)
  end

  defp parse_reason(args) do
    case args do
      ["--reason" | rest] ->
        reason = Enum.join(rest, " ")
        if reason == "", do: "Manual baseline capture", else: reason

      _ ->
        "Manual baseline capture"
    end
  end

  defp capture_error_counts do
    sql = """
    SELECT tool_name, error_type, COUNT(*) as count
    FROM acs_tool_operations
    WHERE status IN ('failure', 'error')
      AND created_at >= datetime('now', '-1 day')
    GROUP BY tool_name, error_type
    ORDER BY count DESC
    LIMIT 20
    """

    query_sql(sql)
  end

  defp query_sql(sql) do
    try do
      {:ok, result} = Ecto.Adapters.SQL.query(Acs.Repo, sql, [], log: false)

      rows =
        Enum.map(result.rows, fn row ->
          Enum.zip(result.columns, row) |> Enum.into(%{})
        end)

      {:ok, rows}
    rescue
      e ->
        Logger.warning("[Baseline] Query failed: #{inspect(e)}")
        {:error, inspect(e)}
    end
    |> case do
      {:ok, rows} -> rows
      _ -> []
    end
  end
end
