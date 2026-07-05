defmodule Acs.MetaHarness.Analyzer do
  @moduledoc """
  Meta-Harness Analyzer for ACS.

  Analyzes operation logs to identify:
  - Tool reliability (success/failure rates)
  - Latency patterns (P50, P95 per tool)
  - Error clusters (grouped by tool + error_type)
  - Agent behavior patterns (derived from operations)

  ## Usage

      analysis = Acs.MetaHarness.Analyzer.analyze(timeframe: :last_24_hours)
  """

  require Logger

  @default_timeframe_days 1

  @doc """
  Main entry point for analysis.

  ## Options
    - `:timeframe` - Analysis window: `:last_24_hours`, `:last_7_days`, `:last_30_days` (default: `:last_24_hours`)
    - `:min_sample_size` - Minimum samples needed for reliable stats (default: 5)
    - `:min_cluster_size` - Minimum occurrences for error cluster detection (default: 2)
  """
  @spec analyze(keyword()) :: map()
  def analyze(opts \\ []) do
    timeframe = Keyword.get(opts, :timeframe, :last_24_hours)
    min_sample = Keyword.get(opts, :min_sample_size, 5)
    min_cluster = Keyword.get(opts, :min_cluster_size, 2)

    {start_time, end_time} = calculate_time_range(timeframe)

    %{
      tool_reliability: analyze_tool_reliability(start_time, end_time, min_sample),
      latency_analysis: analyze_latency(start_time, end_time, min_sample),
      error_clusters: find_error_clusters(start_time, end_time, min_cluster),
      agent_behavior: analyze_agent_behavior(start_time, end_time),
      metadata: %{
        analyzed_at: DateTime.utc_now(),
        timeframe: timeframe,
        start_time: start_time,
        end_time: end_time
      }
    }
  end

  @doc """
  Returns a simple summary for quick inspection.
  """
  @spec quick_summary(keyword()) :: map()
  def quick_summary(opts \\ []) do
    analysis = analyze(opts)

    %{
      total_tools: map_size(analysis.tool_reliability),
      overall_success_rate: calculate_overall_success_rate(analysis.tool_reliability),
      slowest_tool: find_slowest_tool(analysis.latency_analysis),
      most_failed_tool: find_most_failed_tool(analysis.tool_reliability),
      error_cluster_count: length(analysis.error_clusters),
      active_agents: map_size(analysis.agent_behavior)
    }
  end

  # ── Tool Reliability Analysis ────────────────────────────────────────────────

  defp analyze_tool_reliability(start_time, end_time, min_sample) do
    query = """
      SELECT
        tool_name,
        COUNT(*) as total_calls,
        SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END) as success_count,
        SUM(CASE WHEN status = 'failure' THEN 1 ELSE 0 END) as failure_count,
        SUM(CASE WHEN status = 'error' THEN 1 ELSE 0 END) as error_count,
        AVG(latency_ms) as avg_latency,
        MAX(latency_ms) as max_latency
      FROM acs_tool_operations
      WHERE datetime(created_at) >= datetime('#{format_datetime(start_time)}')
        AND datetime(created_at) <= datetime('#{format_datetime(end_time)}')
      GROUP BY tool_name
      HAVING COUNT(*) >= #{min_sample}
      ORDER BY failure_count DESC, total_calls DESC
    """

    case run_query(query) do
      {:ok, results} ->
        Enum.into(results, %{}, fn row ->
          tool_name = row["tool_name"]
          total = row["total_calls"] || 0
          success = row["success_count"] || 0

          {tool_name,
           %{
             total_calls: total,
             success_count: success,
             failure_count: row["failure_count"] || 0,
             error_count: row["error_count"] || 0,
             success_rate: if(total > 0, do: success / total, else: 0.0),
             avg_latency: row["avg_latency"] || 0,
             max_latency: row["max_latency"] || 0
           }}
        end)

      {:error, _} ->
        %{}
    end
  end

  # ── Latency Analysis ─────────────────────────────────────────────────────────
  # SQLite doesn't support PERCENTILE_CONT, so we compute percentiles in Elixir

  defp analyze_latency(start_time, end_time, min_sample) do
    query = """
      SELECT
        tool_name,
        COUNT(*) as sample_size,
        AVG(latency_ms) as avg_latency,
        MIN(latency_ms) as min_latency,
        MAX(latency_ms) as max_latency
      FROM acs_tool_operations
      WHERE datetime(created_at) >= datetime('#{format_datetime(start_time)}')
        AND datetime(created_at) <= datetime('#{format_datetime(end_time)}')
        AND latency_ms IS NOT NULL
      GROUP BY tool_name
      HAVING COUNT(*) >= #{min_sample}
      ORDER BY avg_latency DESC
    """

    # Get raw latency values per tool for percentile calculation
    percentile_query = """
      SELECT tool_name, latency_ms
      FROM acs_tool_operations
      WHERE datetime(created_at) >= datetime('#{format_datetime(start_time)}')
        AND datetime(created_at) <= datetime('#{format_datetime(end_time)}')
        AND latency_ms IS NOT NULL
      ORDER BY tool_name, latency_ms
    """

    case {run_query(query), run_query(percentile_query)} do
      {{:ok, stats_results}, {:ok, raw_results}} ->
        # Group raw latencies by tool_name
        latencies_by_tool = Enum.group_by(raw_results, & &1["tool_name"], & &1["latency_ms"])

        Enum.into(stats_results, %{}, fn row ->
          tool_name = row["tool_name"]
          latencies = Map.get(latencies_by_tool, tool_name, [])

          {tool_name,
           %{
             sample_size: row["sample_size"] || 0,
             avg_latency: row["avg_latency"] || 0,
             min_latency: row["min_latency"] || 0,
             max_latency: row["max_latency"] || 0,
             p50_latency: percentile(latencies, 0.50),
             p95_latency: percentile(latencies, 0.95),
             p99_latency: percentile(latencies, 0.99)
           }}
        end)

      _ ->
        %{}
    end
  end

  # ── Error Cluster Analysis ────────────────────────────────────────────────────

  defp find_error_clusters(start_time, end_time, min_occurrences) do
    query = """
      SELECT
        tool_name,
        error_type,
        error_message,
        COUNT(*) as occurrence_count,
        GROUP_CONCAT(DISTINCT agent_id) as agents
      FROM acs_tool_operations
      WHERE datetime(created_at) >= datetime('#{format_datetime(start_time)}')
        AND datetime(created_at) <= datetime('#{format_datetime(end_time)}')
        AND status IN ('failure', 'error')
        AND error_type IS NOT NULL
      GROUP BY tool_name, error_type
      HAVING COUNT(*) >= #{min_occurrences}
      ORDER BY occurrence_count DESC
      LIMIT 20
    """

    case run_query(query) do
      {:ok, results} ->
        Enum.map(results, fn row ->
          %{
            tool_name: row["tool_name"],
            error_type: row["error_type"],
            sample_message: row["error_message"] && String.slice(row["error_message"], 0, 100),
            occurrence_count: row["occurrence_count"],
            agents: row["agents"] || ""
          }
        end)

      {:error, _} ->
        []
    end
  end

  # ── Agent Behavior Analysis ──────────────────────────────────────────────────
  # Derived from tool_operations table - no separate agent_behavior table needed

  defp analyze_agent_behavior(start_time, end_time) do
    query = """
      SELECT
        agent_id,
        COUNT(*) as total_operations,
        SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END) as success_count,
        SUM(CASE WHEN status IN ('failure', 'error') THEN 1 ELSE 0 END) as failure_count,
        COUNT(DISTINCT tool_name) as unique_tools_used,
        AVG(latency_ms) as avg_latency,
        MIN(created_at) as first_seen,
        MAX(created_at) as last_seen
      FROM acs_tool_operations
      WHERE datetime(created_at) >= datetime('#{format_datetime(start_time)}')
        AND datetime(created_at) <= datetime('#{format_datetime(end_time)}')
        AND agent_id IS NOT NULL
      GROUP BY agent_id
      ORDER BY total_operations DESC
    """

    case run_query(query) do
      {:ok, results} ->
        results
        |> Enum.into(%{}, fn row ->
          agent_id = row["agent_id"]
          total = row["total_operations"] || 0
          success = row["success_count"] || 0

          {agent_id,
           %{
             total_operations: total,
             success_count: success,
             failure_count: row["failure_count"] || 0,
             unique_tools_used: row["unique_tools_used"] || 0,
             success_rate: if(total > 0, do: success / total, else: 0.0),
             avg_latency: row["avg_latency"] || 0,
             first_seen: row["first_seen"],
             last_seen: row["last_seen"]
           }}
        end)
        |> Enum.reject(fn {agent_id, _} -> is_nil(agent_id) or agent_id == "" end)
        |> Enum.into(%{})

      {:error, _} ->
        %{}
    end
  end

  # ── Percentile Calculation ───────────────────────────────────────────────────

  # Calculates percentile from sorted list using linear interpolation
  defp percentile([], _p), do: 0

  defp percentile(sorted_values, p) when is_list(sorted_values) do
    n = length(sorted_values)
    index = (p * (n - 1)) |> Float.ceil() |> max(0) |> min(n - 1) |> round()
    Enum.at(sorted_values, index)
  end

  # ── Helper Functions ─────────────────────────────────────────────────────────

  defp calculate_time_range(:last_24_hours) do
    now = DateTime.utc_now()
    start = DateTime.add(now, -24, :hour)
    {start, now}
  end

  defp calculate_time_range(:last_7_days) do
    now = DateTime.utc_now()
    start = DateTime.add(now, -7, :day)
    {start, now}
  end

  defp calculate_time_range(:last_30_days) do
    now = DateTime.utc_now()
    start = DateTime.add(now, -30, :day)
    {start, now}
  end

  defp calculate_time_range(_) do
    now = DateTime.utc_now()
    start = DateTime.add(now, -@default_timeframe_days, :day)
    {start, now}
  end

  defp format_datetime(dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end

  defp run_query(query) do
    if Code.ensure_loaded?(Acs.Repo) and function_exported?(Acs.Repo, :transaction, 1) do
      try do
        case Ecto.Adapters.SQL.query(Acs.Repo, query, []) do
          {:ok, %Exqlite.Result{} = result} ->
            {:ok,
             Enum.map(result.rows, fn row ->
               Enum.zip(result.columns, row) |> Enum.into(%{})
             end)}

          {:error, reason} ->
            {:error, reason}
        end
      rescue
        e ->
          Logger.warning("[Analyzer] Query failed: #{inspect(e)}")
          {:error, e}
      end
    else
      {:error, :repo_not_available}
    end
  end

  defp calculate_overall_success_rate(tool_reliability) do
    if map_size(tool_reliability) == 0 do
      0.0
    else
      total_calls =
        Enum.reduce(tool_reliability, 0, fn {_, data}, acc -> acc + data.total_calls end)

      total_successes =
        Enum.reduce(tool_reliability, 0, fn {_, data}, acc -> acc + data.success_count end)

      if total_calls > 0 do
        total_successes / total_calls
      else
        0
      end
    end
  end

  defp find_slowest_tool(latency_analysis) do
    case latency_analysis do
      %{} when map_size(latency_analysis) == 0 ->
        nil

      _ ->
        Enum.max_by(latency_analysis, fn {_, data} -> data.avg_latency end)
        |> elem(0)
    end
  end

  defp find_most_failed_tool(tool_reliability) do
    case tool_reliability do
      %{} when map_size(tool_reliability) == 0 ->
        nil

      _ ->
        Enum.max_by(tool_reliability, fn {_, data} -> data.failure_count end)
        |> elem(0)
    end
  end
end
