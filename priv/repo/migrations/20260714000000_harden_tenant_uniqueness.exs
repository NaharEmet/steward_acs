defmodule Acs.Repo.Migrations.HardenTenantUniqueness do
  use Ecto.Migration

  def change do
    drop_if_exists(unique_index(:users, [:email]))
    create(unique_index(:users, [:email, :org], name: :users_email_org_index))

    drop_if_exists(
      unique_index(:acs_file_locks, [:file_path], name: :acs_file_locks_file_path_index)
    )

    create(
      unique_index(:acs_file_locks, [:org, :file_path], name: :acs_file_locks_org_file_path_index)
    )

    # agent_id is the legacy primary key and cannot be changed portably in a
    # cross-adapter migration. Agent identifiers therefore remain globally
    # unique in the database, while all reads and cache keys are org-scoped.
  end
end
