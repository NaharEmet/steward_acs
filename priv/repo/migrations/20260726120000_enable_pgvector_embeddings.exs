defmodule Acs.Repo.Migrations.EnablePgvectorEmbeddings do
  @moduledoc """
  On Postgres/Neon: enable pgvector and store embeddings as `vector(768)`.

  SQLite keeps TEXT JSON (no-op here). Dimension matches nomic-embed-text.
  """
  use Ecto.Migration

  @dim 768

  def up do
    if postgres?() do
      execute("CREATE EXTENSION IF NOT EXISTS vector")

      convert_embedding_column("memory_embeddings")
      convert_embedding_column("spec_embeddings")
      convert_embedding_column("skill_embeddings")

      create_hnsw("memory_embeddings", "memory_embeddings_embedding_hnsw_idx")
      create_hnsw("spec_embeddings", "spec_embeddings_embedding_hnsw_idx")
      create_hnsw("skill_embeddings", "skill_embeddings_embedding_hnsw_idx")
    end
  end

  def down do
    if postgres?() do
      execute("DROP INDEX IF EXISTS memory_embeddings_embedding_hnsw_idx")
      execute("DROP INDEX IF EXISTS spec_embeddings_embedding_hnsw_idx")
      execute("DROP INDEX IF EXISTS skill_embeddings_embedding_hnsw_idx")

      revert_embedding_column("memory_embeddings")
      revert_embedding_column("spec_embeddings")
      revert_embedding_column("skill_embeddings")
    end
  end

  defp create_hnsw(table, index_name) do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = '#{table}'
          AND column_name = 'embedding'
          AND udt_name = 'vector'
      ) THEN
        EXECUTE 'CREATE INDEX IF NOT EXISTS #{index_name}
          ON #{table} USING hnsw (embedding vector_cosine_ops)';
      END IF;
    END $$;
    """)
  end

  defp convert_embedding_column(table) do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = '#{table}'
      ) AND EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = '#{table}'
          AND column_name = 'embedding'
          AND data_type IN ('text', 'character varying')
      ) THEN
        -- Drop rows that cannot cast to vector(#{@dim})
        EXECUTE 'DELETE FROM #{table} WHERE embedding IS NULL
          OR btrim(embedding) = ''''
          OR left(btrim(embedding), 1) <> ''[''
          OR right(btrim(embedding), 1) <> '']''';

        BEGIN
          EXECUTE 'ALTER TABLE #{table}
            ALTER COLUMN embedding TYPE vector(#{@dim})
            USING embedding::vector';
        EXCEPTION WHEN others THEN
          -- Corrupt / wrong-dimension rows: clear and convert empty column
          EXECUTE 'DELETE FROM #{table}';
          EXECUTE 'ALTER TABLE #{table}
            ALTER COLUMN embedding TYPE vector(#{@dim})
            USING embedding::vector';
        END;
      END IF;
    END $$;
    """)
  end

  defp revert_embedding_column(table) do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = '#{table}'
          AND column_name = 'embedding'
          AND udt_name = 'vector'
      ) THEN
        EXECUTE 'ALTER TABLE #{table}
          ALTER COLUMN embedding TYPE text USING embedding::text';
      END IF;
    END $$;
    """)
  end

  defp postgres?, do: repo().__adapter__() == Ecto.Adapters.Postgres
end
