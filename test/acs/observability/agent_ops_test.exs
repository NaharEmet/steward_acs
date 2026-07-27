defmodule Acs.Observability.AgentOpsTest do
  use ExUnit.Case, async: true

  alias Acs.Observability.AgentOps

  test "tool_family classifies retrieve write task other" do
    assert AgentOps.tool_family("ask") == "retrieve"
    assert AgentOps.tool_family("save_memory") == "write"
    assert AgentOps.tool_family("create_work") == "task"
    assert AgentOps.tool_family("help") == "other"
  end

  test "tool_signal maps learning quadrants" do
    assert AgentOps.tool_signal(true, "other", false, nil, false, false) == "misuse_discovery"
    assert AgentOps.tool_signal(false, "retrieve", true, 0, false, false) == "gap_empty"
    assert AgentOps.tool_signal(false, "retrieve", false, 3, false, false) == "works"
    assert AgentOps.tool_signal(false, "retrieve", false, nil, false, false) == nil
    assert AgentOps.tool_signal(false, "write", false, nil, true, false) == "misuse_write"
    assert AgentOps.tool_signal(false, "write", false, nil, false, true) == "surprise_persist"
    assert AgentOps.tool_signal(false, "write", false, nil, false, false) == "works"
  end

  test "feedback_signal prefers win then gap then pain" do
    assert AgentOps.feedback_signal(true, "found X", nil, nil, nil) == "win"
    assert AgentOps.feedback_signal(false, nil, nil, nil, "need pricing") == "gap_info"
    assert AgentOps.feedback_signal(false, nil, "broke", nil, nil) == "pain"
    assert AgentOps.feedback_signal(true, nil, nil, nil, nil) == "works"
  end

  test "log_tool is fire-and-forget when exporters are down" do
    assert :ok =
             AgentOps.log_tool(
               tool_name: "ask",
               result: {:ok, %{summary: %{memory_count: 0, document_count: 0}}},
               latency_ms: 5,
               agent_id: "Ada",
               org: "default",
               audience: "chat",
               scope_path: "acme/pricing"
             )
  end

  test "log_tool tags write_without_retrieve then surprise_persist on same chain" do
    chain = "test-chain-#{System.unique_integer([:positive])}"

    assert :ok =
             AgentOps.log_tool(
               tool_name: "save_memory",
               result: {:ok, %{id: "m1"}},
               agent_id: "Ada",
               org: "default",
               audience: "coding",
               execution_id: chain,
               scope_path: "lib/acs/observability",
               kind: "learning"
             )

    assert :ok =
             AgentOps.log_tool(
               tool_name: "ask",
               result: {:ok, %{summary: %{memory_count: 0, document_count: 0}}},
               agent_id: "Ada",
               org: "default",
               audience: "coding",
               execution_id: chain,
               scope_path: "lib/acs/observability"
             )

    assert :ok =
             AgentOps.log_tool(
               tool_name: "save_memory",
               result: {:ok, %{id: "m2"}},
               agent_id: "Ada",
               org: "default",
               audience: "coding",
               execution_id: chain,
               scope_path: "lib/acs/observability",
               kind: "learning"
             )
  end

  test "log_feedback is fire-and-forget when exporters are down" do
    assert :ok =
             AgentOps.log_feedback(
               agent_id: "Ada",
               org: "default",
               audience: "chat",
               task_id: "t1",
               guidance_useful: true,
               learned_for_agents: "ask before inventing",
               had_issues: "empty ask twice",
               improvements: "seed pricing scope",
               info_needed: "pricing scope"
             )
  end
end
