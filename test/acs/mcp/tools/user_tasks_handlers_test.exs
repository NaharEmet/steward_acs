defmodule Acs.MCP.Tools.UserTasksHandlersTest do
  use Acs.DataCase, async: false

  alias Acs.AuthorityLevels
  alias Acs.MCP.Tools
  alias Acs.PersonStatus
  alias Acs.UserTasks

  setup do
    org = "mcp-user-tasks-#{System.unique_integer([:positive])}"
    Acs.Org.put_request_org(org)
    AuthorityLevels.list(org)

    {:ok, _} =
      PersonStatus.upsert(%{
        "org" => org,
        "name" => "Nahar",
        "status" => "Exec",
        "rank" => "high"
      })

    {:ok, _} =
      PersonStatus.upsert(%{
        "org" => org,
        "name" => "Bob",
        "status" => "IC",
        "rank" => "standard"
      })

    auth = fn name, order ->
      %{
        "agent_id" => name,
        "_auth_agent_id" => name,
        "_auth_org_id" => org,
        "_auth_role" => "collaborator",
        "_auth_audience" => "chat",
        "_auth_authority_sort_order" => order,
        "_auth_authority_level" => if(order == 1, do: "high", else: "standard")
      }
    end

    %{org: org, auth: auth}
  end

  test "create_work kind=user requires due_at and remind_at", %{auth: auth} do
    assert {:error, msg} =
             Tools.call_tool(
               "create_work",
               Map.merge(auth.("Nahar", 1), %{
                 "title" => "Missing times",
                 "kind" => "user"
               })
             )

    assert msg =~ "due_at" or msg =~ "remind_at"
  end

  test "create_work kind=user + get_started pending_reminders + resolve", %{org: org, auth: auth} do
    past = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)
    due = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    assert {:ok, created} =
             Tools.call_tool(
               "create_work",
               Map.merge(auth.("Nahar", 1), %{
                 "title" => "Follow up vendor",
                 "kind" => "user",
                 "due_at" => DateTime.to_iso8601(due),
                 "remind_at" => DateTime.to_iso8601(past)
               })
             )

    assert created.kind == "user"
    assert created.status == "ok"
    task_id = created.task_id

    assert {:ok, packet} =
             Tools.call_tool(
               "get_started",
               Map.merge(auth.("Nahar", 1), %{"audience" => "chat"})
             )

    assert is_list(packet.pending_reminders)
    assert Enum.any?(packet.pending_reminders, &(&1.id == task_id))
    assert packet.pending_reminders_guidance =~ "steward_work"
    assert packet.user_task_protocol =~ "remind_later"
    assert packet.get_started =~ "Pending reminders"

    assert {:error, snooze_msg} =
             Tools.call_tool(
               "resolve_user_task",
               Map.merge(auth.("Nahar", 1), %{
                 "task_id" => task_id,
                 "outcome" => "remind_later"
               })
             )

    assert snooze_msg =~ "remind_at"

    later = DateTime.utc_now() |> DateTime.add(7200, :second) |> DateTime.truncate(:second)

    assert {:ok, %{outcome: "remind_later", task_status: "todo"}} =
             Tools.call_tool(
               "resolve_user_task",
               Map.merge(auth.("Nahar", 1), %{
                 "task_id" => task_id,
                 "outcome" => "remind_later",
                 "remind_at" => DateTime.to_iso8601(later)
               })
             )

    refute Enum.any?(UserTasks.pending_reminders("Nahar", org), &(&1.id == task_id))

    assert {:ok, %{outcome: "done", task_status: "done"}} =
             Tools.call_tool(
               "resolve_user_task",
               Map.merge(auth.("Nahar", 1), %{
                 "task_id" => task_id,
                 "outcome" => "done"
               })
             )
  end

  test "list_tasks kind=user defaults to self; for_user needs clearance", %{auth: auth} do
    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
    due = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    assert {:ok, _} =
             Tools.call_tool(
               "create_work",
               Map.merge(auth.("Bob", 3), %{
                 "title" => "Bob reminder",
                 "kind" => "user",
                 "due_at" => DateTime.to_iso8601(due),
                 "remind_at" => DateTime.to_iso8601(past)
               })
             )

    assert {:ok, %{kind: "user", count: 1}} =
             Tools.call_tool(
               "list_tasks",
               Map.merge(auth.("Bob", 3), %{"kind" => "user"})
             )

    assert {:ok, %{kind: "user", count: 1}} =
             Tools.call_tool(
               "list_tasks",
               Map.merge(auth.("Nahar", 1), %{"kind" => "user", "for_user" => "Bob"})
             )

    assert {:error, msg} =
             Tools.call_tool(
               "list_tasks",
               Map.merge(auth.("Bob", 3), %{"kind" => "user", "for_user" => "Nahar"})
             )

    assert msg =~ "not allowed" or msg =~ "clearance"
  end

  test "higher clearance can create for subordinate; peer assign fails", %{auth: auth} do
    past = DateTime.utc_now() |> DateTime.truncate(:second)
    due = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    assert {:ok, %{assignee: "Bob"}} =
             Tools.call_tool(
               "create_work",
               Map.merge(auth.("Nahar", 1), %{
                 "title" => "Assigned to Bob",
                 "kind" => "user",
                 "assignee" => "Bob",
                 "due_at" => DateTime.to_iso8601(due),
                 "remind_at" => DateTime.to_iso8601(past)
               })
             )

    assert {:error, msg} =
             Tools.call_tool(
               "create_work",
               Map.merge(auth.("Bob", 3), %{
                 "title" => "Upward assign",
                 "kind" => "user",
                 "assignee" => "Nahar",
                 "due_at" => DateTime.to_iso8601(due),
                 "remind_at" => DateTime.to_iso8601(past)
               })
             )

    assert msg =~ "lower clearance" or msg =~ "higher"
  end

  test "dismiss removes task from pending_reminders", %{org: org, auth: auth} do
    past = DateTime.utc_now() |> DateTime.add(-30, :second) |> DateTime.truncate(:second)
    due = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    assert {:ok, %{task_id: task_id}} =
             Tools.call_tool(
               "create_work",
               Map.merge(auth.("Nahar", 1), %{
                 "title" => "Dismiss me",
                 "kind" => "user",
                 "due_at" => DateTime.to_iso8601(due),
                 "remind_at" => DateTime.to_iso8601(past)
               })
             )

    assert Enum.any?(UserTasks.pending_reminders("Nahar", org), &(&1.id == task_id))

    assert {:ok, %{outcome: "dismiss", task_status: "dismissed"}} =
             Tools.call_tool(
               "resolve_user_task",
               Map.merge(auth.("Nahar", 1), %{
                 "task_id" => task_id,
                 "outcome" => "dismiss"
               })
             )

    refute Enum.any?(UserTasks.pending_reminders("Nahar", org), &(&1.id == task_id))
  end

  test "default list_tasks excludes user reminders", %{auth: auth} do
    past = DateTime.utc_now() |> DateTime.truncate(:second)
    due = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    assert {:ok, _} =
             Tools.call_tool(
               "create_work",
               Map.merge(auth.("Nahar", 1), %{
                 "title" => "User only #{System.unique_integer([:positive])}",
                 "kind" => "user",
                 "due_at" => DateTime.to_iso8601(due),
                 "remind_at" => DateTime.to_iso8601(past)
               })
             )

    assert {:ok, %{kind: "coordination", tasks: tasks}} =
             Tools.call_tool("list_tasks", auth.("Nahar", 1))

    refute Enum.any?(tasks, &(&1[:kind] == "user" or Map.get(&1, :kind) == "user"))
  end
end
