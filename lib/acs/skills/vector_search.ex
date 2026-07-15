defmodule Acs.Skills.VectorSearch do
  require Logger

  @table_name "skill_embeddings"

  def create_table(repo \\ Acs.Repo) do
    repo.query("""
      CREATE TABLE IF NOT EXISTS #{@table_name} (
        skill_name TEXT NOT NULL,
        org TEXT NOT NULL DEFAULT 'default',
        embedding TEXT NOT NULL,
        updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (skill_name, org)
      )
    """)

    :ok
  end

  def upsert_embedding(skill_name, embedding, org \\ Acs.Org.current(), repo \\ Acs.Repo)
      when is_binary(skill_name) and is_list(embedding) and is_binary(org) do
    embedding_json = Jason.encode!(embedding)

    repo.query(
      """
      INSERT INTO #{@table_name} (skill_name, org, embedding, updated_at)
      VALUES (?, ?, ?, datetime('now'))
      ON CONFLICT(skill_name, org) DO UPDATE SET
        embedding = excluded.embedding,
        updated_at = excluded.updated_at
      """,
      [skill_name, org, embedding_json]
    )

    :ok
  end

  def remove_embedding(skill_name, org \\ Acs.Org.current(), repo \\ Acs.Repo)
      when is_binary(skill_name) and is_binary(org) do
    repo.query("DELETE FROM #{@table_name} WHERE skill_name = ? AND org = ?", [
      skill_name,
      org
    ])

    :ok
  end

  def search(query, opts \\ []) when is_binary(query) do
    limit = Keyword.get(opts, :limit, 20)
    org = org_filter(opts)

    with {:ok, embedding} <- Acs.Memory.Embedding.embed_text(query) do
      sql =
        if org do
          {"SELECT skill_name, embedding FROM #{@table_name} WHERE org = ?", [org]}
        else
          {"SELECT skill_name, embedding FROM #{@table_name}", []}
        end

      {q, params} = sql

      case Acs.Repo.query(q, params) do
        {:ok, %{rows: rows}} when is_list(rows) ->
          scored =
            rows
            |> Enum.map(fn [skill_name, embedding_json] ->
              case Jason.decode(embedding_json) do
                {:ok, emb} ->
                  %{
                    skill_name: skill_name,
                    similarity:
                      Acs.Memory.Embedding.cosine_similarity(embedding, emb)
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
    else
      {:error, reason} ->
        Logger.warning("[Skills.VectorSearch] Embedding failed: #{reason}")
        {:error, reason}
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

  defp org_filter(opts) do
    case Keyword.get(opts, :org) do
      org when is_binary(org) and org != "" -> org
      _ -> if Acs.Org.multi_tenant?(), do: Acs.Org.current(), else: nil
    end
  end
end
