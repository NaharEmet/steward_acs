defmodule Acs.Repo.Migrations.FixReleasedStatusToDone do
  use Ecto.Migration

  def up do
    execute "UPDATE acs_tasks SET status = 'done' WHERE status = 'released'"
  end

  def down do
    execute "UPDATE acs_tasks SET status = 'released' WHERE status = 'done'"
  end
end