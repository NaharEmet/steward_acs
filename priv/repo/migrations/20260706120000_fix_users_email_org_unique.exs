defmodule Acs.Repo.Migrations.FixUsersEmailOrgUnique do
  use Ecto.Migration

  def change do
    drop_if_exists unique_index(:users, [:email])
    create unique_index(:users, [:email, :org], name: :users_email_org_unique)
  end
end
