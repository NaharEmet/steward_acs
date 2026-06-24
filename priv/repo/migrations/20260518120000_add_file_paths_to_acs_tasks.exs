defmodule Acs.Repo.Migrations.AddFilePathsToAcsTasks do
  use Ecto.Migration

  def change do
    alter table(:acs_tasks) do
      add(:file_paths, {:array, :string}, default: [])
    end
  end
end
