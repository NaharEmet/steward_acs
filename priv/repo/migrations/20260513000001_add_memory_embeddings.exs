defmodule Acs.Repo.Migrations.AddMemoryEmbeddings do
  use Ecto.Migration

  def up do
    execute """
    CREATE TABLE IF NOT EXISTS memory_embeddings (
      memory_id TEXT PRIMARY KEY,
      embedding TEXT NOT NULL,
      updated_at TEXT DEFAULT CURRENT_TIMESTAMP
    )
    """
  end

  def down do
    execute "DROP TABLE IF EXISTS memory_embeddings"
  end
end