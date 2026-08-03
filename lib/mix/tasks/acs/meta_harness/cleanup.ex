defmodule Mix.Tasks.Acs.MetaHarness.Cleanup do
  @moduledoc """
  Cleans up old operation logs based on retention policy.

  ## Usage

      mix acs.meta_harness.cleanup

  Default retention: 30 days
  """

  use Mix.Task

  @retention_days 30

  @impl Mix.Task
  def run(_args) do
    deleted = delete_old_records()
    Mix.Shell.IO.info("Deleted #{deleted} records older than #{@retention_days} days")
  end

  defp delete_old_records do
    if Code.ensure_loaded?(Acs.Repo) and function_exported?(Acs.Repo, :transaction, 1) do
      try do
        cutoff = DateTime.add(DateTime.utc_now(), -@retention_days, :day)

        result =
          Ecto.Adapters.SQL.query(
            Acs.Repo,
            Acs.MetaHarness.SQL.adapt("""
              DELETE FROM acs_tool_operations 
              WHERE created_at < ?1
            """),
            [cutoff]
          )

        result.num_rows
      rescue
        e ->
          Mix.Shell.IO.error("Cleanup failed: #{inspect(e)}")
          0
      end
    else
      0
    end
  end
end
