defmodule Acs.Memory.VectorIndex do
  @moduledoc """
  Vector storage and similarity search for memory embeddings.

  Stores embeddings as JSON in a TEXT column. Similarity search
  loads vectors into memory and uses cosine similarity.
  """

  alias Acs.Memory.Retry

  @table_name "memory_embeddings"

  @doc """
  Create the memory_embeddings table if it doesn't exist.
  """
  def create_embeddings_table(repo \\ Acs.Repo) do
    repo.query("""
      CREATE TABLE IF NOT EXISTS #{@table_name} (
        memory_id TEXT PRIMARY KEY,
        embedding TEXT NOT NULL,
        updated_at TEXT DEFAULT CURRENT_TIMESTAMP
      )
    """)

    :ok
  end

  @doc """
  Store or update embedding for a memory.
  """
  def upsert_embedding(memory_id, embedding, repo \\ Acs.Repo)
      when is_binary(memory_id) and is_list(embedding) do
    embedding_json = Jason.encode!(embedding)

    Retry.with_busy_retry(fn ->
      repo.query(
        """
          INSERT INTO #{@table_name} (memory_id, embedding, updated_at)
          VALUES (?, ?, datetime('now'))
          ON CONFLICT(memory_id) DO UPDATE SET
            embedding = excluded.embedding,
            updated_at = excluded.updated_at
        """,
        [memory_id, embedding_json]
      )
    end)

    :ok
  end

  @doc """
  Find top-k similar memories by embedding.
  Returns list of %{memory_id: string, similarity: float} maps.
  """
  @spec search_similar([float()], keyword(), module()) :: [
          %{memory_id: String.t(), similarity: float()}
        ]
  def search_similar(embedding, options \\ [], repo \\ Acs.Repo)
      when is_list(embedding) and is_list(options) do
    limit = Keyword.get(options, :limit, 10)

    case repo.query("SELECT memory_id, embedding FROM #{@table_name}") do
      {:ok, %{rows: rows}} when is_list(rows) ->
        rows
        |> Enum.map(fn [memory_id, embedding_json] ->
          case Jason.decode(embedding_json) do
            {:ok, emb} ->
              %{
                memory_id: memory_id,
                similarity: Acs.Memory.Embedding.cosine_similarity(embedding, emb)
              }

            _ ->
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.similarity, :desc)
        |> Enum.take(limit)

      _ ->
        []
    end
  end

  @doc """
  Delete embedding when memory is deleted.
  """
  def remove_embedding(memory_id, repo \\ Acs.Repo) when is_binary(memory_id) do
    Retry.with_busy_retry(fn ->
      repo.query("DELETE FROM #{@table_name} WHERE memory_id = ?", [memory_id])
    end)

    :ok
  end

  @doc """
  Find memories above similarity threshold.
  """
  @spec search_threshold([float()], float(), module()) :: [
          %{memory_id: String.t(), similarity: float()}
        ]
  def search_threshold(embedding, threshold, repo \\ Acs.Repo)
      when is_list(embedding) and is_number(threshold) do
    embedding
    |> search_similar(limit: 1000, repo: repo)
    |> Enum.filter(&(&1.similarity >= threshold))
  end
end
