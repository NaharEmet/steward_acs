defmodule Acs.Repo.Migrations.AddGuidanceFieldsToTaskCompletionFeedback do
  use Ecto.Migration

  def change do
    alter table(:task_completion_feedback) do
      add :guidance_useful, :boolean
      add :guidance_items_helpful, :text
      add :guidance_items_confusing, :text
      add :guidance_missing, :text
    end
  end
end