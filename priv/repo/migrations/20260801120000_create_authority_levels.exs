defmodule Acs.Repo.Migrations.CreateAuthorityLevels do
  use Ecto.Migration

  def up do
    create table(:acs_authority_levels, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :org, :string, null: false
      add :slug, :string, null: false
      add :label, :string, null: false
      add :sort_order, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:acs_authority_levels, [:org, :slug],
             name: :acs_authority_levels_org_slug_index
           )

    create unique_index(:acs_authority_levels, [:org, :sort_order],
             name: :acs_authority_levels_org_sort_order_index
           )

    create index(:acs_authority_levels, [:org], name: :acs_authority_levels_org_index)

    alter table(:users) do
      add :authority_level_slug, :string, null: true
    end

    alter table(:acs_memories) do
      add :authority_sort_order, :integer, null: true
    end
  end

  def down do
    alter table(:acs_memories) do
      remove :authority_sort_order
    end

    alter table(:users) do
      remove :authority_level_slug
    end

    drop_if_exists index(:acs_authority_levels, [:org], name: :acs_authority_levels_org_index)

    drop_if_exists unique_index(:acs_authority_levels, [:org, :sort_order],
                     name: :acs_authority_levels_org_sort_order_index
                   )

    drop_if_exists unique_index(:acs_authority_levels, [:org, :slug],
                     name: :acs_authority_levels_org_slug_index
                   )

    drop table(:acs_authority_levels)
  end
end
