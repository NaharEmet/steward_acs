defmodule Acs.MCP.Tools.StandaloneFeedbackTest do
  use Acs.DataCase, async: false

  alias Acs.MCP.Tools.ErrorHandlers
  alias Acs.Acs.TaskCompletionFeedback

  # task_completion_feedback.task_id is a foreign key to acs_tasks, so standalone
  # feedback must leave it nil rather than inventing an id no task owns.
  test "standalone feedback without task_id inserts with a nil task_id" do
    assert {:ok, %{feedback_id: id}} =
             ErrorHandlers.acs_submit_task_feedback(%{
               "agent_id" => "test-agent",
               "learned_for_agents" => "Standalone feedback must not fabricate a task_id."
             })

    assert %TaskCompletionFeedback{task_id: nil, agent_id: "test-agent"} =
             Repo.get(TaskCompletionFeedback, id)
  end
end
