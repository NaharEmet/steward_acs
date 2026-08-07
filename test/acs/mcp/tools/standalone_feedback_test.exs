defmodule Acs.MCP.Tools.StandaloneFeedbackTest do
  use Acs.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Acs.MCP.Tools.ErrorHandlers
  alias Acs.Acs.TaskCompletionFeedback

  # task_completion_feedback.task_id is a foreign key to acs_tasks, so standalone
  # feedback must leave it nil rather than inventing an id no task owns. The
  # response no longer exposes the feedback row id (agents never see DB ids).
  test "standalone feedback without task_id inserts with a nil task_id" do
    assert {:ok, %{message: _}} =
             ErrorHandlers.acs_submit_task_feedback(%{
               "agent_id" => "test-agent",
               "learned_for_agents" => "Standalone feedback must not fabricate a task_id."
             })

    assert %TaskCompletionFeedback{task_id: nil, agent_id: "test-agent"} =
             Repo.one(
               from f in TaskCompletionFeedback,
                 where: f.agent_id == "test-agent" and is_nil(f.task_id),
                 order_by: [desc: f.inserted_at],
                 limit: 1
             )
  end
end
