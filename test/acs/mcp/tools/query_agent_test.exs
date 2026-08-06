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

  test "small document hit inlines full content" do
    entry = %Acs.Specs.Entry{
      app: "steward_acs",
      id: "documents/reference/linear-pm",
      title: "Linear/Scrum Master Agent (PM-facing)",
      document_type: "reference",
      content:
        "Ask clarifying questions before filing tickets. Confirm priority, cycle, and estimate."
    }

    rendered = QueryAgent.render_documents([entry])
    assert rendered =~ "full content"
    assert rendered =~ "Ask clarifying questions before filing tickets"
    assert rendered =~ "steward_acs/documents/reference/linear-pm"
  end

  test "many documents stay catalog-only with fetch hint" do
    docs =
      for i <- 1..3 do
        %Acs.Specs.Entry{
          app: "steward_acs",
          id: "documents/reference/doc-#{i}",
          title: "Doc #{i}",
          document_type: "reference",
          content: "Body #{i} with enough text to show as an excerpt for catalog mode."
        }
      end

    rendered = QueryAgent.render_documents(docs)
    refute rendered =~ "full content"
    assert rendered =~ "excerpts"
    assert rendered =~ "Excerpt:"
    assert rendered =~ "Body 1 with enough text"

    assert rendered =~
             ~s|steward_ask(action:"document", app:"steward_acs", path:"documents/reference/doc-1")|

    assert rendered =~ "fetch the full document"
  end

  test "oversized single document does not inline" do
    # > 5k tokens at ~4 chars/token
    big = String.duplicate("word ", 6_000)

    entry = %Acs.Specs.Entry{
      app: "steward_acs",
      id: "documents/reference/huge",
      title: "Huge",
      document_type: "reference",
      content: big
    }

    rendered = QueryAgent.render_documents([entry])
    refute rendered =~ "full content"
    assert rendered =~ "Excerpt:"

    assert rendered =~
             ~s|steward_ask(action:"document", app:"steward_acs", path:"documents/reference/huge")|

    refute QueryAgent.under_inline_token_limit?(big)
  end

  test "skills always catalog with fetch required never full content" do
    rendered =
      QueryAgent.render_skills([
        %{
          name: "linear-pm",
          description: "File Linear tickets with clarifying questions",
          when_to_use: "Before creating Linear tickets",
          tags: ["linear"]
        }
      ])

    refute rendered =~ "full content"
    assert rendered =~ "fetch required"
    assert rendered =~ "Excerpt:"
    assert rendered =~ "When to use: Before creating Linear tickets"

    assert rendered =~
             ~s|steward_ask(action:"skill", name:"linear-pm")|

    assert rendered =~ "required before following this procedure"
  end
end
