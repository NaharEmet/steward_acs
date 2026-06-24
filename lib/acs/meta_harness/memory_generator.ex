defmodule Acs.MetaHarness.MemoryGenerator do
  @moduledoc """
  Generates memory entries from Meta-Harness findings.
  
  Only creates memories for significant issues (quality gates):
  - Error rate > 10%
  - Latency p95 > 500ms
  """

  require Logger

  @error_threshold 0.10
  @latency_threshold_ms 500

  @doc """
  Analyzes and generates memories from recent data.
  Returns list of generated memory titles.
  """
  @spec generate_memories(keyword()) :: [String.t()]
  def generate_memories(opts \\ []) do
    timeframe = Keyword.get(opts, :timeframe, :last_24_hours)
    analysis = Acs.MetaHarness.Analyzer.analyze(timeframe: timeframe)
    
    findings = []
    
    # High failure rate tools
    failing = Enum.filter(analysis.tool_reliability, fn {_, d} -> d.success_rate < (1 - @error_threshold) end)
    findings = findings ++ Enum.map(failing, fn {name, data} ->
      {:high_failure_rate, name, data}
    end)
    
    # Slow tools
    slow = Enum.filter(analysis.latency_analysis, fn {_, d} -> (d.p95_latency || 0) > @latency_threshold_ms end)
    findings = findings ++ Enum.map(slow, fn {name, data} ->
      {:slow_tool, name, data}
    end)
    
    # Generate memories for findings
    Enum.map(findings, fn finding ->
      save_memory(finding)
    end)
  end

  defp save_memory({:high_failure_rate, tool_name, data}) do
    summary = "High failure rate: #{tool_name} (#{(data.success_rate * 100.0) |> Float.round(1)}%)"
    Logger.warning("[MemoryGenerator] #{summary}")

    memory = Acs.Memory.new(%{
      "kind" => "warning",
      "title" => "high_failure_rate_#{tool_name}",
      "summary" => summary,
      "content" => """
      Tool `#{tool_name}` has a high failure rate of #{(data.success_rate * 100.0) |> Float.round(1)}%.
      Total calls: #{data.total_calls}, Failures: #{data.failure_count + data.error_count}
      """,
      "scope_path" => "generated_insights/tool_reliability",
      "importance" => 4,
      "tags" => ["meta_harness", "high_failure_rate", tool_name],
      "triggers" => ["tool_reliability_analysis"],
      "failure_modes" => ["tool_unavailable", "input_validation_error", "timeout"]
    })

    case Acs.Memory.Loader.save(memory) do
      :ok -> "#{tool_name}: high failure rate"
      {:error, reason} ->
        Logger.error("[MemoryGenerator] Failed to save memory: #{inspect(reason)}")
        "#{tool_name}: high failure rate (save failed)"
    end
  end

  defp save_memory({:slow_tool, tool_name, data}) do
    summary = "Slow tool: #{tool_name} (p95: #{data.p95_latency}ms)"
    Logger.warning("[MemoryGenerator] #{summary}")

    memory = Acs.Memory.new(%{
      "kind" => "warning",
      "title" => "slow_tool_#{tool_name}",
      "summary" => summary,
      "content" => """
      Tool `#{tool_name}` has high latency. P95: #{data.p95_latency}ms, P99: #{data.p99_latency}ms, Avg: #{data.avg_latency}ms.
      Sample size: #{data.sample_size} calls.
      """,
      "scope_path" => "generated_insights/tool_latency",
      "importance" => 3,
      "tags" => ["meta_harness", "slow_tool", tool_name],
      "triggers" => ["latency_analysis"],
      "failure_modes" => ["backend_slow", "rate_limited", "large_response"]
    })

    case Acs.Memory.Loader.save(memory) do
      :ok -> "#{tool_name}: slow tool"
      {:error, reason} ->
        Logger.error("[MemoryGenerator] Failed to save memory: #{inspect(reason)}")
        "#{tool_name}: slow tool (save failed)"
    end
  end
end