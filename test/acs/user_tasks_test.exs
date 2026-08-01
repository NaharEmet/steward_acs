defmodule Acs.UserTasksTest do
  use Acs.DataCase, async: false

  alias Acs.AuthorityLevels
  alias Acs.PersonStatus
  alias Acs.UserTasks

  setup do
    org = "user-tasks-#{System.unique_integer([:positive])}"
    Acs.Org.put_request_org(org)
    AuthorityLevels.list(org)

    {:ok, _} =
      PersonStatus.upsert(%{
        "org" => org,
        "name" => "Alice",
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

    {:ok, _} =
      PersonStatus.upsert(%{
        "org" => org,
        "name" => "Carol",
        "status" => "Peer",
        "rank" => "high"
      })

    %{org: org}
  end

  test "create requires due_at and remind_at", %{org: org} do
    assert {:error, msg} =
             UserTasks.create(%{"title" => "Call bank"}, "Alice",
               org: org,
               viewer_sort_order: 1
             )

    assert msg =~ "due_at"
  end

  test "remind_at after due_at is rejected", %{org: org} do
    due = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
    later = DateTime.utc_now() |> DateTime.add(7200, :second) |> DateTime.truncate(:second)

    assert {:error, msg} =
             UserTasks.create(
               %{
                 "title" => "Bad window",
                 "due_at" => DateTime.to_iso8601(due),
                 "remind_at" => DateTime.to_iso8601(later)
               },
               "Alice",
               org: org,
               viewer_sort_order: 1
             )

    assert msg =~ "remind_at"
  end

  test "dismiss removes from pending_reminders", %{org: org} do
    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
    due = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    assert {:ok, task} =
             UserTasks.create(
               %{
                 "title" => "Dismiss unit",
                 "due_at" => DateTime.to_iso8601(due),
                 "remind_at" => DateTime.to_iso8601(past)
               },
               "Alice",
               org: org,
               viewer_sort_order: 1
             )

    assert {:ok, dismissed} =
             UserTasks.resolve(task.id, "Alice", "dismiss", org: org, viewer_sort_order: 1)

    assert dismissed.status == "dismissed"
    refute Enum.any?(UserTasks.pending_reminders("Alice", org), &(&1.id == task.id))
  end

  test "create self task and pending_reminders after remind_at", %{org: org} do
    past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
    due = DateTime.utc_now() |> DateTime.add(86400, :second) |> DateTime.truncate(:second)

    assert {:ok, task} =
             UserTasks.create(
               %{
                 "title" => "Prep QBR",
                 "due_at" => DateTime.to_iso8601(due),
                 "remind_at" => DateTime.to_iso8601(past)
               },
               "Alice",
               org: org,
               viewer_sort_order: 1
             )

    assert task.kind == "user"
    assert task.assignee == "Alice"
    assert task.status == "todo"

    pending = UserTasks.pending_reminders("Alice", org)
    assert Enum.any?(pending, &(&1.id == task.id))
  end

  test "future remind_at is not pending yet", %{org: org} do
    future = DateTime.utc_now() |> DateTime.add(86400, :second) |> DateTime.truncate(:second)

    assert {:ok, task} =
             UserTasks.create(
               %{
                 "title" => "Later",
                 "due_at" => DateTime.to_iso8601(future),
                 "remind_at" => DateTime.to_iso8601(future)
               },
               "Alice",
               org: org,
               viewer_sort_order: 1
             )

    refute Enum.any?(UserTasks.pending_reminders("Alice", org), &(&1.id == task.id))
  end

  test "higher clearance can assign to lower; peers cannot", %{org: org} do
    due = DateTime.utc_now() |> DateTime.add(86400, :second) |> DateTime.truncate(:second)
    remind = DateTime.utc_now() |> DateTime.truncate(:second)

    assert {:ok, _} =
             UserTasks.create(
               %{
                 "title" => "For Bob",
                 "assignee" => "Bob",
                 "due_at" => DateTime.to_iso8601(due),
                 "remind_at" => DateTime.to_iso8601(remind)
               },
               "Alice",
               org: org,
               viewer_sort_order: 1
             )

    assert {:error, msg} =
             UserTasks.create(
               %{
                 "title" => "Peer fail",
                 "assignee" => "Carol",
                 "due_at" => DateTime.to_iso8601(due),
                 "remind_at" => DateTime.to_iso8601(remind)
               },
               "Alice",
               org: org,
               viewer_sort_order: 1
             )

    assert msg =~ "lower clearance"
  end

  test "list: same/higher can query; lower cannot", %{org: org} do
    due = DateTime.utc_now() |> DateTime.add(86400, :second) |> DateTime.truncate(:second)
    remind = DateTime.utc_now() |> DateTime.truncate(:second)

    assert {:ok, _} =
             UserTasks.create(
               %{
                 "title" => "Bob task",
                 "due_at" => DateTime.to_iso8601(due),
                 "remind_at" => DateTime.to_iso8601(remind)
               },
               "Bob",
               org: org,
               viewer_sort_order: 3
             )

    assert {:ok, tasks} =
             UserTasks.list("Alice", org: org, viewer_sort_order: 1, for_user: "Bob")

    assert length(tasks) == 1

    assert {:ok, _} = UserTasks.list("Carol", org: org, viewer_sort_order: 1, for_user: "Bob")

    assert {:error, _} =
             UserTasks.list("Bob", org: org, viewer_sort_order: 3, for_user: "Alice")
  end

  test "resolve done / dismiss / remind_later requires time", %{org: org} do
    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
    due = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    assert {:ok, task} =
             UserTasks.create(
               %{
                 "title" => "Resolve me",
                 "due_at" => DateTime.to_iso8601(due),
                 "remind_at" => DateTime.to_iso8601(past)
               },
               "Alice",
               org: org,
               viewer_sort_order: 1
             )

    assert {:error, msg} =
             UserTasks.resolve(task.id, "Alice", "remind_later", org: org, viewer_sort_order: 1)

    assert msg =~ "remind_at"

    later = DateTime.utc_now() |> DateTime.add(7200, :second) |> DateTime.truncate(:second)

    assert {:ok, snoozed} =
             UserTasks.resolve(task.id, "Alice", "remind_later",
               org: org,
               viewer_sort_order: 1,
               remind_at: DateTime.to_iso8601(later)
             )

    assert snoozed.status == "todo"
    refute Enum.any?(UserTasks.pending_reminders("Alice", org), &(&1.id == task.id))

    assert {:ok, done} =
             UserTasks.resolve(task.id, "Alice", "done", org: org, viewer_sort_order: 1)

    assert done.status == "done"
  end

  test "coordination list_tasks excludes user tasks", %{org: org} do
    due = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
    remind = DateTime.utc_now() |> DateTime.truncate(:second)

    assert {:ok, _} =
             UserTasks.create(
               %{
                 "title" => "Hidden from coordination list",
                 "due_at" => DateTime.to_iso8601(due),
                 "remind_at" => DateTime.to_iso8601(remind)
               },
               "Alice",
               org: org,
               viewer_sort_order: 1
             )

    assert {:ok, _coord} =
             Acs.create_task(%{"title" => "coord-#{System.unique_integer([:positive])}"}, "Alice")

    refute Enum.any?(Acs.list_tasks(nil, org), &(&1.kind == "user"))
  end
end
