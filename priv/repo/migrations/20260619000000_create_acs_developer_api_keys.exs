defmodule Acs.Repo.Migrations.CreateAcsDeveloperApiKeys do
  use Ecto.Migration

  def change do
    create table(:acs_developer_api_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :key_hash, :string, null: false
      add :key_prefix, :string
      add :developer_name, :string, null: false
      add :role, :string, default: "admin"
      add :cluster, :string, default: "default"
      add :active, :boolean, default: true
      add :last_used_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:acs_developer_api_keys, [:key_hash], name: :acs_dev_keys_hash_unique)
    create index(:acs_developer_api_keys, [:cluster], name: :acs_dev_keys_cluster_index)
    create index(:acs_developer_api_keys, [:active], name: :acs_dev_keys_active_index)
  end
end
