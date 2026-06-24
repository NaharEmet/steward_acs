defmodule Acs.LogAnalyzer do
  @moduledoc """
  Periodic log analyzer that extracts errors from the LogStore, groups similar
  errors by component and message pattern, and generates actionable insights.

  Runs every 60 seconds and stores analysis results in state.
  Can also call back to the main app's LLM for AI-powered optimization suggestions.
  """

  use GenServer
  require Logger
  alias Acs.MCP.ErrorTrace

  # Main app endpoint for AI analysis
  @main_app_url "http://localhost:4000"

  # ── Client API ──

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the latest analysis results.
  """
  def get_analysis do
    GenServer.call(__MODULE__, :get_analysis, 5_000)
  end

  @doc """
  Returns a formatted error report as a string.
  """
  def get_error_report do
    GenServer.call(__MODULE__, :get_error_report, 5_000)
  end

  @doc """
  Requests AI-powered optimization suggestions by sending error patterns
  to the main app for LLM analysis. Returns the AI response or error message.
  """
  def request_ai_optimization do
    GenServer.call(__MODULE__, :request_ai_optimization, 30_000)
  end

  # ── Callbacks ──

  @impl true
  def init(_opts) do
    Logger.info("[LogAnalyzer] Starting periodic error analysis (interval: 60s)")

    schedule_analysis()

    {:ok, %{
      last_analysis: nil,
      error_groups: [],
      total_errors: 0,
      top_components: [],
      recent_alerts: [],
      ai_suggestions: nil,
      summary: "No analysis yet"
    }}
  end

  @impl true
  def handle_info(:run_analysis, state) do
    new_state = perform_analysis(state)
    schedule_analysis()
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:get_analysis, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call(:get_error_report, _from, state) do
    report = format_report(state)
    {:reply, report, state}
  end

  @impl true
  def handle_call(:request_ai_optimization, _from, state) do
    result = do_request_ai_optimization(state)
    new_state = %{state | ai_suggestions: result}
    {:reply, result, new_state}
  end

  # ── Analysis ──

  defp schedule_analysis do
    Process.send_after(self(), :run_analysis, 60_000)
  end

  defp perform_analysis(state) do
    try do
      recent_errors = fetch_recent_errors()

    # Guard clause: if no errors, return state as-is
    if recent_errors == [] do
      Logger.info("[LogAnalyzer] No errors found in last 5 minutes")

      %{state |
        last_analysis: DateTime.utc_now(),
        error_groups: [],
        total_errors: 0,
        top_components: [],
        recent_alerts: [],
        summary: %{
          analyzed_at: DateTime.utc_now(),
          total_errors: 0,
          error_components: [],
          top_error_patterns: [],
          alerts: []
        }
      }
    else
      # Group errors by component
      by_component =
        recent_errors
        |> Enum.group_by(fn e -> Map.get(e, :cmp, "unknown") end)
        |> Enum.map(fn {comp, logs} ->
          %{component: comp, count: length(logs), samples: Enum.take(logs, 3)}
        end)
        |> Enum.sort_by(fn g -> g.count end, :desc)

      # Group errors by message pattern (first 100 chars of message as rough pattern)
      by_pattern =
        recent_errors
        |> Enum.group_by(fn e ->
          msg = Map.get(e, :msg, "")
          String.slice(msg, 0, 100)
        end)
        |> Enum.map(fn {pattern, logs} ->
          %{
            pattern: pattern,
            count: length(logs),
            component: Map.get(hd(logs), :cmp, "unknown"),
            service: Map.get(hd(logs), :svc, "unknown"),
            first_seen: Enum.min_by(logs, &parse_ts(Map.get(&1, :ts))),
            last_seen: Enum.max_by(logs, &parse_ts(Map.get(&1, :ts)))
          }
        end)
        |> Enum.sort_by(fn g -> g.count end, :desc)
        |> Enum.take(20)

      # ── Error Trace Integration ──
      # Track ignored components that should not auto-create tasks
      ignored_components = ["Acs::Acs::Cache", "Acs::MCP::LogStore"]

      Enum.each(by_pattern, fn g ->
        metadata = %{}

        case ErrorTrace.store_or_update_trace(
               g.service,
               g.component,
               g.pattern,
               g.pattern,
               metadata
             ) do
          {:ok, _action, trace} when is_map(trace) ->
            # Only create task if:
            # 1. Pattern count >= 8 (severe)
            # 2. Trace status is :new (not already tasked)
            # 3. Component is not in the ignored list
            if trace.count >= 8 and trace.status == :new and
                 g.component not in ignored_components do
              create_task_for_trace(g, trace)
            end

          {:error, :no_table} ->
            Logger.warning(
              "[LogAnalyzer] ErrorTrace table not available - error traces will not be stored for #{g.service}/#{g.component}"
            )

          {:error, :nil_message_pattern} ->
            Logger.debug(
              "[LogAnalyzer] Nil message pattern for #{g.service}/#{g.component} - pattern was nil"
            )

          other ->
            Logger.warning(
              "[LogAnalyzer] Unexpected return from ErrorTrace.store_or_update_trace for #{g.service}/#{g.component}: #{inspect(other)}"
            )
        end
      end)

      # Generate simple alert for heavily repeated errors
      alerts =
        by_pattern
        |> Enum.filter(fn g -> g.count >= 5 end)
        |> Enum.map(fn g ->
          "⚠️ [#{g.service}/#{g.component}] '#{String.slice(g.pattern, 0, 80)}...' repeated #{g.count} times"
        end)

      # Build summary
      summary = %{
        analyzed_at: DateTime.utc_now(),
        total_errors: length(recent_errors),
        error_components: Enum.map(by_component, &%{name: &1.component, count: &1.count}),
        top_error_patterns: Enum.take(by_pattern, 10),
        alerts: alerts
      }

      Logger.info(
        "[LogAnalyzer] Analysis complete: #{length(recent_errors)} errors, #{length(by_pattern)} patterns, #{length(alerts)} alerts"
      )

      %{state |
        last_analysis: DateTime.utc_now(),
        error_groups: by_pattern,
        total_errors: length(recent_errors),
        top_components: by_component,
        recent_alerts: alerts,
        summary: summary
      }
    end
  rescue
    e ->
      Logger.error("[LogAnalyzer] Crash during analysis: #{inspect(e)}")
      Logger.error(Exception.format_stacktrace(__STACKTRACE__))
      state
  end
  end

  defp fetch_recent_errors do
    # Get errors from the last 5 minutes using LogStore
    # Returns formatted entries with keys: :id, :ts, :lvl, :svc, :cmp, :msg
    result = Acs.MCP.LogStore.get_logs([level: :error, limit: 500], "list")

    Map.get(result, :logs, [])
  end

  # ── AI Optimization ──

  defp do_request_ai_optimization(state) do
    if state.total_errors == 0 do
      "No errors to analyze. AI optimization skipped."
    else
      prompt = build_ai_prompt(state)

      case call_main_app_ai(prompt) do
        {:ok, response} ->
          response

        {:error, reason} ->
          "AI analysis unavailable: #{inspect(reason)}.\n\nTo use AI optimization, ensure the main app is running on #{@main_app_url}."
      end
    end
  end

  defp build_ai_prompt(state) do
    """
    I am a system operations AI analyzing error logs from a multi-service application.

    ERROR ANALYSIS REPORT:
    - Total errors in last 5 minutes: #{state.total_errors}
    - Unique error patterns: #{length(state.error_groups)}

    TOP ERROR COMPONENTS:
    #{Enum.map_join(Enum.take(state.top_components, 5), "\n", fn g ->
      "  - #{g.component}: #{g.count} errors"
    end)}

    ERROR PATTERNS:
    #{Enum.map_join(Enum.take(state.error_groups, 5), "\n---\n", fn g ->
      "  Service: #{g.service}\n  Component: #{g.component}\n  Count: #{g.count}\n  Pattern: #{g.pattern}"
    end)}

    ALERTS:
    #{if state.recent_alerts == [], do: "  None\n", else: Enum.map_join(state.recent_alerts, "\n", &"  - #{&1}") <> "\n"}

    Based on this error data, please provide:
    1. Root cause analysis - what is the most likely root cause
    2. Optimization suggestions - how to fix or mitigate each pattern
    3. Priority order - which issues to address first
    4. Monitoring recommendations - what to watch for

    Format as a structured response with clear sections.
    """
  end

  defp call_main_app_ai(prompt) do
    url = "#{@main_app_url}/api/ai/analyze"

    body = %{
      prompt: prompt,
      context: "log_analysis",
      source: "steward_acs_log_analyzer"
    }

    request = Req.new(
      url: url,
      method: :post,
      json: body,
      receive_timeout: 15_000,
      retry: false
    )

    case Req.request(request) do
      {:ok, %{status: 200, body: response_body}} ->
        {:ok, response_body}

      {:ok, %{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Parse ISO8601 timestamp string back to DateTime for comparison
  defp parse_ts(nil), do: DateTime.from_unix!(0)
  defp parse_ts(%DateTime{} = dt), do: dt
  defp parse_ts(ts) when is_integer(ts), do: DateTime.from_unix!(ts)
  defp parse_ts(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> DateTime.from_unix!(0)
    end
  end

  defp parse_ts(_), do: DateTime.from_unix!(0)

  # ── Reporting ──

  defp format_report(state) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    lines = [
      "╔══════════════════════════════════════╗",
      "║     ACS Log Analyzer Report          ║",
      "╚══════════════════════════════════════╝",
      "",
      "Generated: #{timestamp}",
      "Last Analysis: #{format_datetime(state.last_analysis)}",
      "",
      "── Error Summary ──",
      "Total Errors (last 5 min): #{state.total_errors}",
      "Unique Patterns: #{length(state.error_groups)}",
      ""
    ]

    lines = lines ++ ["── Top Components ──"]
    lines = lines ++ Enum.map(state.top_components, fn g ->
      "  #{g.component}: #{g.count} errors"
    end)

    lines = lines ++ ["", "── Alerts ──"]
    lines = lines ++ if state.recent_alerts == [] do
      ["  ✅ No significant error patterns detected"]
    else
      state.recent_alerts
    end

    lines = lines ++ ["", "── Top Error Patterns ──"]
    lines = lines ++ if state.error_groups == [] do
      ["  No errors recorded"]
    else
      Enum.map(Enum.take(state.error_groups, 10), fn g ->
        "  [x#{g.count}] #{g.service}/#{g.component}: #{String.slice(g.pattern, 0, 120)}"
      end)
    end

    lines = lines ++ ["", "── AI Optimization Suggestions ──"]

    lines =
      if state.ai_suggestions do
        lines ++ [state.ai_suggestions]
      else
        lines ++ ["  No AI analysis requested yet. Call request_ai_optimization() to generate suggestions."]
      end

    Enum.join(lines, "\n")
  end

  defp format_datetime(nil), do: "never"
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp format_datetime(%{} = map) do
    ts = Map.get(map, :ts) || Map.get(map, :timestamp)
    case parse_ts(ts) do
      %DateTime{} = dt -> DateTime.to_iso8601(dt)
      _ -> "never"
    end
  end

  defp format_datetime(_), do: "unknown"

  defp create_task_for_trace(g, trace) do
    task_title =
      "Auto: #{g.service}/#{g.component} error repeated #{g.count}x"

    task_description =
      "Error pattern: #{String.slice(g.pattern, 0, 200)}\n\n" <>
        "From LogAnalyzer analysis at #{DateTime.utc_now() |> DateTime.to_iso8601()}\n" <>
        "Total occurrences: #{g.count}\n" <>
        "First seen: #{format_datetime(g.first_seen)}\n" <>
        "Last seen: #{format_datetime(g.last_seen)}"

    case Acs.create_task(%{
           "title" => task_title,
           "description" => task_description,
           "file_paths" => []
         }, "log_analyzer") do
      {:ok, task} ->
        Logger.info(
          "[LogAnalyzer] Created auto-task #{task.id} for #{g.service}/#{g.component} (#{g.count}x)"
        )
        ErrorTrace.mark_tasked(trace.id, task.id)

      {:warn, task, _similar} ->
        Logger.info(
          "[LogAnalyzer] Created auto-task #{task.id} (with similar warnings) for #{g.service}/#{g.component}"
        )
        ErrorTrace.mark_tasked(trace.id, task.id)

      {:error, reason} ->
        Logger.warning(
          "[LogAnalyzer] Failed to create auto-task for #{g.service}/#{g.component}: #{inspect(reason)}"
        )
        ErrorTrace.mark_failed(trace.id, inspect(reason))
    end
  end
end
