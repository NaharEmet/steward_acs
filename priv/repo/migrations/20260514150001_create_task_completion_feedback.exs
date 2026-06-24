defmodule Acs.Repo.Migrations.CreateTaskCompletionFeedback do
  use Ecto.Migration

  def change do
    create table(:task_completion_feedback) do
      add :task_id, references(:acs_tasks, type: :binary_id, on_delete: :delete_all)
      add :agent_id, :string
      add :most_surprising, :text
      add :most_time_consuming, :text
      add :improvements_needed, :text
      add :tools_wish_list, :text
      add :info_needed, :text
      timestamps(type: :utc_datetime)
    end

    create index(:task_completion_feedback, [:task_id])
    create index(:task_completion_feedback, [:agent_id])
  end
end