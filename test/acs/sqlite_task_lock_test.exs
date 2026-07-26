defmodule Acs.SqliteTaskLockTest do
  use Acs.DataCase, async: false

  test "claim and release task under sqlite without crashing" do
    {:ok, task} =
      Acs.Org.with_current("default", fn ->
        Acs.create_task(%{"title" => "sqlite-lock-#{System.unique_integer([:positive])}"}, "agent-a")
      end)

    assert {:ok, _claimed, _guidance} =
             Acs.Org.with_current("default", fn ->
               Acs.claim_task(task.id, "agent-a")
             end)

    assert {:ok, _released} =
             Acs.Org.with_current("default", fn ->
               Acs.release_task(task.id, "agent-a")
             end)
  end
end
