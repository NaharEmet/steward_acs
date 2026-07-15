defmodule Acs.Memory.VectorIndex do
  @moduledoc """
  Vector storage and similarity search for memory embeddings.

  Stores embeddings as JSON in a TEXT column, scoped by org in multi-tenant mode.
  """

  alias Acs.Memory.Retry

  @table_name "memory_embeddings"

  @doc """
  Create the memory_embeddings table if it doesn't exist.
  """
  def create_embeddings_table(repo \\ Acs.Repo) do
    repo.query("""
      CREATE TABLE IF NOT EXISTS #{@table_name} (
        memory_id TEXT NOT NULL,
        org TEXT NOT NULL DEFAULT 'default',
        embedding TEXT NOT NULL,
        updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (memory_id, org)
      )
    """)

    :ok
  end

  @doc """
  Store or update embedding for a memory, scoped to an org.
  """
  def upsert_embedding(memory_id, embedding, org \\ Acs.Org.current(), repo \\ Acs.Repo)
      when is_binary(memory_id) and is_list(embedding) and is_binary(org) do
    embedding_json = Jason.encode!(embedding)
    index_id = Acs.Org.memory_index_id(memory_id, org)

    Retry.with_busy_retry(fn ->
      repo.query(
        """
          INSERT INTO #{@table_name} (memory_id, org, embedding, updated_at)
          VALUES (?, ?, ?, datetime('now'))
          ON CONFLICT(memory_id, org) DO UPDATE SET
            embedding = excluded.embedding,
            updated_at = excluded.updated_at
        """,
        [index_id, org, embedding_json]
      )
    end)

    :ok
  end

  @doc """
  Find top-k similar memories by embedding, optionally scoped to an org.
  """
  @spec search_similar([float()], keyword(), module()) :: [
          %{memory_id: String.t(), similarity: float()}
        ]
  def search_similar(embedding, options \\ [], repo \\ Acs.Repo)
      when is_list(embedding) and is_list(options) do
    limit = Keyword.get(options, :limit, 10)
    org = org_filter(options)

    sql =
      if org do
        {"SELECT memory_id, embedding FROM #{@table_name} WHERE org = ?", [org]}
      else
        {"SELECT memory_id, embedding FROM #{@table_name}", []}
      end

    {query, params} = sql

    case repo.query(query, params) do
      {:ok, %{rows: rows}} when is_list(rows) ->
        rows
        |> Enum.map(fn [memory_id, embedding_json] ->
          case Jason.decode(embedding_json) do
            {:ok, emb} ->
              %{
                memory_id: Acs.Org.public_memory_id(memory_id, org || Acs.Org.current()),
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
  def remove_embedding(memory_id, org \\ Acs.Org.current(), repo \\ Acs.Repo)
      when is_binary(memory_id) and is_binary(org) do
    index_id = Acs.Org.memory_index_id(memory_id, org)

    Retry.with_busy_retry(fn ->
      repo.query("DELETE FROM #{@table_name} WHERE memory_id = ? AND org = ?", [
        index_id,
        org
      ])
    end)

    :ok
  end

  @doc """
  Find memories above similarity threshold, optionally scoped to an org.
  """
  @spec search_threshold([float()], float(), keyword(), module()) :: [
          %{memory_id: String.t(), similarity: float()}
        ]
  def search_threshold(embedding, threshold, options \\ [], repo \\ Acs.Repo)
      when is_list(embedding) and is_number(threshold) do
    embedding
    |> search_similar(Keyword.put(options, :limit, 1000), repo)
    |> Enum.filter(&(&1.similarity >= threshold))
  end

  defp org_filter(options) do
    case Keyword.get(options, :org) do
      org when is_binary(org) and org != "" -> org
      _ -> if Acs.Org.multi_tenant?(), do: Acs.Org.current(), else: nil
    end
  end
end
