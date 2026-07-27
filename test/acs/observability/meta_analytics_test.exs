defmodule Acs.Observability.MetaAnalyticsTest do
  use ExUnit.Case, async: true

  alias Acs.Observability.MetaAnalytics

  test "ship is fire-and-forget when exporters are down" do
    analysis = %{
      tool_reliability: %{
        "ask" => %{
          total_calls: 10,
          success_count: 8,
          failure_count: 2,
          error_count: 0,
          discovery_count: 1,
          success_rate: 0.8,
          avg_latency: 12.0,
          max_latency: 40
        }
      },
      latency_analysis: %{
        "ask" => %{p50_latency: 10, p95_latency: 30}
      },
      error_clusters: [
        %{
          tool_name: "ask",
          error_type: "timeout",
          sample_message: "timed out",
          occurrence_count: 2,
          agents: "Ada"
        }
      ],
      agent_behavior: %{
        "Ada" => %{
          total_operations: 10,
          success_count: 8,
          failure_count: 2,
          discovery_count: 1,
          unique_tools_used: 3,
          success_rate: 0.8,
          avg_latency: 12.0
        }
      },
      metadata: %{timeframe: :last_24_hours}
    }

    assert :ok = MetaAnalytics.ship(analysis)
    assert :ok = MetaAnalytics.ship(%{})
    assert :ok = MetaAnalytics.ship(nil)
  end
end
