defmodule Acs.MCP.Tools.ListTasksNextStepTest do
  use Acs.DataCase, async: false

  alias Acs.MCP.Tools

  setup do
    org = "next-step-#{System.unique_integer([:positive])}"
    Acs.Org.put_request_org(org)
    %{org: org}
  end

  defp coding_auth(org, agent) do
    %{
      "agent_id" => agent,
      "_auth_agent_id" => agent,
      "_auth_org_id" => org,
      "_auth_role" => "collaborator",
      "_auth_audience" => "coding"
    }
  end

  test "suggests claiming only the caller's own todo task", %{org: org} do
    {:ok, mine} =
      Acs.create_task(%{"title" => "Mine #{System.unique_integer([:positive])}"}, "nahar")

    {:ok, theirs} =
      Acs.create_task(%{"title" => "Theirs #{System.unique_integer([:positive])}"}, "other")

    assert {:ok, %{tasks: tasks, _next: next}} =
             Tools.call_tool(
               "list_tasks",
               Map.merge(coding_auth(org, "nahar"), %{"status_filter" => "todo"})
             )

    assert Enum.map(tasks, & &1[:slug]) |> Enum.sort() ==
             Enum.sort([mine.slug, theirs.slug])

    assert [%{tool: "claim_work", params: %{task_id: slug}}] = next
    assert slug == mine.slug
  end

  test "falls back to create_work when the caller has no own todo tasks", %{org: org} do
    {:ok, _theirs} =
      Acs.create_task(%{"title" => "Theirs #{System.unique_integer([:positive])}"}, "other")

    assert {:ok, %{_next: next}} =
             Tools.call_tool(
               "list_tasks",
               Map.merge(coding_auth(org, "nahar"), %{"status_filter" => "todo"})
             )

    assert [%{tool: "create_work", params: %{title: "..."}}] = next
  end
end
