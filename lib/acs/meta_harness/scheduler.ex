defmodule Acs.MetaHarness.Scheduler do
  @moduledoc """
  Periodic scheduler for ACS Meta-Harness aggregation tasks.

  Runs on a configurable interval (default: 1 hour) to:
  - Run `Acs.MetaHarness.Analyzer` analysis
  - Generate report via `Acs.MetaHarness.DocumentGenerator.generate/1`

  The interval can be configured via the `META_HARNESS_INTERVAL_MS` environment variable.
  """

  use GenServer

  require Logger

  @default_interval :timer.hours(1)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, default_interval())

    Logger.info(
      "[Acs.MetaHarness.Scheduler] Starting with interval: #{div(interval, 60000)} minutes"
    )

    schedule_next_run(interval)

    {:ok, %{interval: interval, last_run: nil}}
  end

  @impl true
  def handle_info(:run_analysis, state) do
    _start_time = System.monotonic_time(:millisecond)

    Logger.info("[Acs.MetaHarness.Scheduler] Starting analysis cycle")

    try do
      {elapsed, _results} = :timer.tc(fn -> run_analysis_cycle() end)

      Logger.info("[Acs.MetaHarness.Scheduler] Analysis completed in #{div(elapsed, 1000)}ms")

      schedule_next_run(state.interval)

      {:noreply, %{state | last_run: DateTime.utc_now()}}
    rescue
      e ->
        stacktrace = __STACKTRACE__
        Logger.error("[Acs.MetaHarness.Scheduler] Message handling crashed: #{inspect(e)}")
        Logger.error("[Acs.MetaHarness.Scheduler] Stacktrace: #{inspect(stacktrace)}")
        # Always reschedule next run even on error - GenServer must stay alive
        schedule_next_run(state.interval)
        {:noreply, %{state | last_run: DateTime.utc_now()}}
    end
  end

  defp schedule_next_run(interval) do
    Process.send_after(self(), :run_analysis, interval)
  end

  defp run_analysis_cycle do
    Logger.info("[Scheduler] Running Meta-Harness analysis...")

    try do
      # Wrap entire cycle in top-level rescue so Scheduler never crashes
      # The Generator.generate() function does all the work; we just need to
      # ensure it never crashes the GenServer
      result = Acs.MetaHarness.Generator.generate()
      Logger.info("[Scheduler] Generated report: #{inspect(result)}")
      result
    rescue
      e ->
        stacktrace = __STACKTRACE__
        Logger.error("[Scheduler] Analysis cycle crashed: #{inspect(e)}")
        Logger.error("[Scheduler] Stacktrace: #{inspect(stacktrace)}")
        %{error: inspect(e), stacktrace: inspect(stacktrace)}
    end
  end

  defp default_interval do
    case System.get_env("META_HARNESS_INTERVAL_MS") do
      nil ->
        @default_interval

      val when is_binary(val) ->
        case Integer.parse(val) do
          {ms, _} when ms > 0 -> ms
          _ -> @default_interval
        end

      _ ->
        @default_interval
    end
  end

  @doc """
  Manually trigger an analysis cycle.
  """
  @spec trigger_analysis() :: map()
  def trigger_analysis do
    run_analysis_cycle()
  end

  @doc """
  Get scheduler status.
  """
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :get_status)
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, %{interval: state.interval, last_run: state.last_run}, state}
  end
end
