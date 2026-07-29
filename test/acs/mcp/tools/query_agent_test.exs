defmodule Acs.MCP.Tools.QueryAgentTest do
  use Acs.DataCase, async: false

  alias Acs.MCP.Tools.QueryAgent

  test "ask with content_query returns structured summary" do
    {:ok, result} =
      QueryAgent.ask(%{
        "content_query" => "cache release ordering",
        "include_documents" => false,
        "include_skills" => false,
        "include_agent_status" => false,
        "limit" => 5
      })

    assert is_map(result)
    assert is_binary(result.response)
    assert is_map(result.summary)
    assert Map.has_key?(result.summary, :memory_count)
    assert Map.has_key?(result.summary, :skill_count)
    assert is_list(result.relevant_skills)
  end

  test "ask without content_query still works" do
    {:ok, result} =
      QueryAgent.ask(%{
        "include_documents" => false,
        "include_skills" => false,
        "include_agent_status" => false,
        "limit" => 5
      })

    assert is_map(result)
    assert is_binary(result.response)
    assert result.relevant_skills == []
  end

  test "ask can return related skills for a content query" do
    {:ok, result} =
      QueryAgent.ask(%{
        "content_query" => "deploy",
        "include_documents" => false,
        "include_agent_status" => false,
        "limit" => 5
      })

    assert is_list(result.relevant_skills)
    assert is_integer(result.summary.skill_count)
  end
end
