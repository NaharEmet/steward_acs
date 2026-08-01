defmodule Acs.Skills.VectorSearch do
  require Logger

  alias Acs.Repo.Pgvector

  @table_name "skill_embeddings"

  def create_table(repo \\ Acs.Repo) do
    if Pgvector.enabled?(repo) do
      repo.query("CREATE EXTENSION IF NOT EXISTS vector")

      repo.query("""
        CREATE TABLE IF NOT EXISTS #{@table_name} (
          skill_name TEXT NOT NULL,
          org TEXT NOT NULL DEFAULT 'default',
          embedding vector(#{Pgvector.dimensions()}) NOT NULL,
          updated_at TIMESTAMPTZ DEFAULT NOW(),
          PRIMARY KEY (skill_name, org)
        )
      """)

      repo.query("""
        CREATE INDEX IF NOT EXISTS skill_embeddings_embedding_hnsw_idx
          ON #{@table_name} USING hnsw (embedding vector_cosine_ops)
      """)
    else
      repo.query("""
        CREATE TABLE IF NOT EXISTS #{@table_name} (
          skill_name TEXT NOT NULL,
          org TEXT NOT NULL DEFAULT 'default',
          embedding TEXT NOT NULL,
          updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
          PRIMARY KEY (skill_name, org)
        )
      """)
    end

    :ok
  end

  def upsert_embedding(skill_name, embedding, org \\ Acs.Org.current(), repo \\ Acs.Repo)
      when is_binary(skill_name) and is_list(embedding) and is_binary(org) do
    vector_literal = Pgvector.encode(embedding)

    if Pgvector.enabled?(repo) do
      repo.query(
        """
        INSERT INTO #{@table_name} (skill_name, org, embedding, updated_at)
        VALUES ($1, $2, ($3::text)::vector, NOW())
        ON CONFLICT (skill_name, org) DO UPDATE SET
          embedding = EXCLUDED.embedding,
          updated_at = EXCLUDED.updated_at
        """,
        [skill_name, org, vector_literal]
      )
    else
      repo.query(
        """
        INSERT INTO #{@table_name} (skill_name, org, embedding, updated_at)
        VALUES (?, ?, ?, datetime('now'))
        ON CONFLICT(skill_name, org) DO UPDATE SET
          embedding = excluded.embedding,
          updated_at = excluded.updated_at
        """,
        [skill_name, org, vector_literal]
      )
    end

    :ok
  end

  def remove_embedding(skill_name, org \\ Acs.Org.current(), repo \\ Acs.Repo)
      when is_binary(skill_name) and is_binary(org) do
    if Pgvector.enabled?(repo) do
      repo.query("DELETE FROM #{@table_name} WHERE skill_name = $1 AND org = $2", [
        skill_name,
        org
      ])
    else
      repo.query("DELETE FROM #{@table_name} WHERE skill_name = ? AND org = ?", [
        skill_name,
        org
      ])
    end

    :ok
  end

  def search(query, opts \\ []) when is_binary(query) do
    limit = Keyword.get(opts, :limit, 20)
    org = Pgvector.org_filter(opts)

    with {:ok, embedding} <- Pgvector.resolve_embedding(query, opts) do
      if Pgvector.enabled?() do
        search_pg(embedding, org, limit)
      else
        search_sqlite(embedding, org, limit)
      end
    else
      {:error, reason} ->
        Logger.warning("[Skills.VectorSearch] Embedding failed: #{reason}")
        {:error, reason}
    end
  end

  defp search_pg(embedding, org, limit) do
    vector_literal = Pgvector.encode(embedding)

    {sql, params} =
      if org do
        {"""
         SELECT skill_name, 1 - (embedding <=> ($1::text)::vector) AS similarity
         FROM #{@table_name}
         WHERE org = $2
         ORDER BY embedding <=> ($1::text)::vector
         LIMIT $3
         """, [vector_literal, org, limit]}
      else
        {"""
         SELECT skill_name, 1 - (embedding <=> ($1::text)::vector) AS similarity
         FROM #{@table_name}
         ORDER BY embedding <=> ($1::text)::vector
         LIMIT $2
         """, [vector_literal, limit]}
      end

    case Acs.Repo.query(sql, params) do
      {:ok, %{rows: rows}} when is_list(rows) ->
        scored =
          Enum.map(rows, fn [skill_name, similarity] ->
            %{skill_name: skill_name, similarity: Pgvector.to_float(similarity)}
          end)

        {:ok, scored}

      _ ->
        {:ok, []}
    end
  end

  defp search_sqlite(embedding, org, limit) do
    {q, params} =
      if org do
        {"SELECT skill_name, embedding FROM #{@table_name} WHERE org = ?", [org]}
      else
        {"SELECT skill_name, embedding FROM #{@table_name}", []}
      end

    case Acs.Repo.query(q, params) do
      {:ok, %{rows: rows}} when is_list(rows) ->
        scored =
          rows
          |> Enum.map(fn [skill_name, embedding_json] ->
            case Jason.decode(embedding_json) do
              {:ok, emb} ->
                %{
                  skill_name: skill_name,
                  similarity: Acs.Memory.Embedding.cosine_similarity(embedding, emb)
                }

              _ ->
                nil
            end
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.sort_by(& &1.similarity, :desc)
          |> Enum.take(limit)

        {:ok, scored}

      _ ->
        {:ok, []}
    end
  end

  def ensure_embeddings do
    unless Acs.Memory.Embedding.available?() do
      Logger.warning("[Skills.VectorSearch] Ollama not available, skipping")
      {:error, "Ollama unavailable"}
    else
      do_ensure_embeddings()
    end
  end

  defp do_ensure_embeddings do
    create_table()

    skills = Acs.Skills.Store.list_skills()
    existing = existing_embeddings()

    to_embed =
      Enum.reject(skills, fn skill ->
        MapSet.member?(existing, skill["name"])
      end)

    {embedded, failed} =
      Enum.reduce(to_embed, {0, 0}, fn skill, {emb_acc, fail_acc} ->
        text = retrieval_text(skill)

        case Acs.Memory.Embedding.embed_text(text) do
          {:ok, embedding} ->
            upsert_embedding(skill["name"], embedding)
            {emb_acc + 1, fail_acc}

          {:error, reason} ->
            Logger.warning("[Skills.VectorSearch] Failed to embed #{skill["name"]}: #{reason}")
            {emb_acc, fail_acc + 1}
        end
      end)

    stats = %{
      total: length(skills),
      existing: MapSet.size(existing),
      embedded: embedded,
      failed: failed
    }

    Logger.info(
      "[Skills.VectorSearch] ensure_embeddings: #{stats.total} total, #{stats.existing} existing, #{stats.embedded} new, #{stats.failed} failed"
    )

    {:ok, stats}
  end

  defp retrieval_text(skill) do
    [
      "Title: #{skill["name"]}",
      "Description: #{skill["description"] || ""}",
      "Tags: #{Enum.join(skill["tags"] || [], ", ")}",
      "Content: #{String.slice(skill["content"] || "", 0, 2000)}"
    ]
    |> Enum.reject(&(&1 == "" or String.ends_with?(&1, ": ")))
    |> Enum.join("\n\n")
  end

  defp existing_embeddings do
    case Acs.Repo.query("SELECT skill_name FROM #{@table_name}") do
      {:ok, %{rows: rows}} ->
        rows |> Enum.map(fn [name] -> name end) |> MapSet.new()

      {:error, _} ->
        MapSet.new()
    end
  end
end
