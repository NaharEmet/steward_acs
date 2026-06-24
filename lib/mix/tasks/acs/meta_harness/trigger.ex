defmodule Mix.Tasks.Acs.MetaHarness.Trigger do
  @moduledoc """
  Manually triggers an ACS Meta-Harness analysis cycle.

  ## Usage

      mix acs.meta_harness.trigger

  This calls `Acs.MetaHarness.Scheduler.trigger_analysis/0` to run
  the analyzer and document generator immediately, outside of the
  normal scheduled interval.
  """

  use Mix.Task

  require Logger

  @impl Mix.Task
  def run(_args) do
    Logger.info("[Acs.MetaHarness.Trigger] Starting manual analysis trigger")

    start_if_not_running()
    trigger_and_report()
  end

  defp start_if_not_running do
    Mix.Task.run("app.start", [])
    :ok
  end

  defp trigger_and_report do
    result = Acs.MetaHarness.Scheduler.trigger_analysis()

    case result do
      %{error: _} ->
        Mix.Shell.IO.error("Generation failed. Check logs for details.")
        exit({:shutdown, 1})

      _ ->
        Mix.Shell.IO.info("Analysis cycle completed successfully.")
        Mix.Shell.IO.info("Last run: #{inspect(result[:timestamp])}")
    end
  end
end