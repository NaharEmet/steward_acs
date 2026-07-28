defmodule Acs.Repo.Migrations.CreateAcsPersonStatuses do
  use Ecto.Migration

  def change do
    create table(:acs_person_statuses, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:org, :string, null: false)
      add(:email, :string)
      add(:name, :string, null: false)
      add(:status, :string, null: false)
      add(:rank, :string, null: false, default: "standard")
      add(:updated_by, :string)

      timestamps(type: :utc_datetime)
    end

    create(index(:acs_person_statuses, [:org], name: :acs_person_statuses_org_index))
    create(index(:acs_person_statuses, [:org, :name], name: :acs_person_statuses_org_name_index))

    # SQLite treats NULLs as distinct in UNIQUE indexes, so multiple name-only rows are fine.
    create(
      unique_index(:acs_person_statuses, [:org, :email], name: :acs_person_statuses_org_email_index)
    )
  end
end
