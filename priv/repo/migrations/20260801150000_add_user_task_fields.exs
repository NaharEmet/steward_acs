defmodule Acs.Repo.Migrations.AddUserTaskFields do
  use Ecto.Migration

  def change do
    alter table(:acs_tasks) do
      add :kind, :string, null: false, default: "coordination"
      add :assignee, :string
      add :due_at, :utc_datetime
      add :remind_at, :utc_datetime
      add :authority_sort_order, :integer
    end

    create index(:acs_tasks, [:org, :kind, :assignee])
    create index(:acs_tasks, [:org, :kind, :remind_at])
  end
end
