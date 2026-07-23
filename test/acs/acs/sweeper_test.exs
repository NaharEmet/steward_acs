defmodule Acs.Acs.SweeperTest do
  use Acs.DataCase, async: false

  alias Acs.Acs.Sweeper
  alias Acs.Acs.Task

  test "returns expired task leases to todo and clears their claim" do
    task =
      %Task{}
      |> Task.changeset(%{
        title: "expired lease",
        created_by_agent: "creator",
        status: "in_progress",
        locked_by_agent: "worker",
        locked_at: DateTime.add(DateTime.utc_now(), -11, :minute),
        auto_release_at: DateTime.add(DateTime.utc_now(), -1, :second)
      })
      |> Repo.insert!()

    Phoenix.PubSub.subscribe(AcsWeb.PubSub, "acs")
    Sweeper.sweep_now()

    assert_receive {:task_released, %{task_id: task_id, agent_id: "worker"}}, 1_000
    assert task_id == task.id

    updated = Repo.get!(Task, task.id)
    assert updated.status == "todo"
    assert updated.locked_by_agent == nil
    assert updated.locked_at == nil
    assert updated.auto_release_at == nil
  end
end
