defmodule Acs.Specs.VectorSearch do
  @moduledoc """
  Vector search and RAG retrieval for spec entries.

  Chunks large specs (document-type with lots of content) into segments
  and indexes each chunk with its source/origin context. Enables semantic
  retrieval of relevant spec fragments with provenance tracking.
  """

  require Logger

  alias Acs.Repo.Pgvector
  alias Acs.Specs.Entry
  alias Acs.Specs.Loader

  @table_name "spec_embeddings"
  @chunk_max_words 500
  @chunk_overlap_words 50

  def create_table(repo \\ Acs.Repo) do
    if Pgvector.enabled?(repo) do
      repo.query("CREATE EXTENSION IF NOT EXISTS vector")

      repo.query("""
        CREATE TABLE IF NOT EXISTS #{@table_name} (
          id TEXT NOT NULL,
          app TEXT NOT NULL DEFAULT '',
          path TEXT NOT NULL DEFAULT '',
          chunk_index INTEGER NOT NULL DEFAULT 0,
          source TEXT DEFAULT '',
          content TEXT NOT NULL DEFAULT '',
          org TEXT NOT NULL DEFAULT 'default',
          embedding vector(#{Pgvector.dimensions()}) NOT NULL,
          updated_at TIMESTAMPTZ DEFAULT NOW(),
          PRIMARY KEY (id, org)
        )
      """)

      repo.query("""
        CREATE INDEX IF NOT EXISTS spec_embeddings_embedding_hnsw_idx
          ON #{@table_name} USING hnsw (embedding vector_cosine_ops)
      """)
    else
      repo.query("""
        CREATE TABLE IF NOT EXISTS #{@table_name} (
          id TEXT NOT NULL,
          app TEXT NOT NULL DEFAULT '',
          path TEXT NOT NULL DEFAULT '',
          chunk_index INTEGER NOT NULL DEFAULT 0,
          source TEXT DEFAULT '',
          content TEXT NOT NULL DEFAULT '',
          org TEXT NOT NULL DEFAULT 'default',
          embedding TEXT NOT NULL,
          updated_at TEXT DEFAULT CURRENT_TIMESTAMP,
          PRIMARY KEY (id, org)
        )
      """)
    end

    repo.query("""
      CREATE INDEX IF NOT EXISTS idx_spec_embeddings_app_path
      ON #{@table_name} (app, path)
    """)

    :ok
  end

  def upsert_chunk(id, app, path, chunk_index, source, content, embedding, org \\ Acs.Org.current(), repo \\ Acs.Repo)
      when is_binary(id) and is_list(embedding) do
    vector_literal = Pgvector.encode(embedding)

    if Pgvector.enabled?(repo) do
      repo.query(
        """
        INSERT INTO #{@table_name} (id, app, path, chunk_index, source, content, org, embedding, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7, ($8::text)::vector, NOW())
        ON CONFLICT (id, org) DO UPDATE SET
          embedding = EXCLUDED.embedding,
          content = EXCLUDED.content,
          source = EXCLUDED.source,
          updated_at = EXCLUDED.updated_at
        """,
        [id, app, path, chunk_index, source, content, org, vector_literal]
      )
    else
      repo.query(
        """
        INSERT INTO #{@table_name} (id, app, path, chunk_index, source, content, org, embedding, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
        ON CONFLICT(id, org) DO UPDATE SET
          embedding = excluded.embedding,
          content = excluded.content,
          source = excluded.source,
          updated_at = excluded.updated_at
        """,
        [id, app, path, chunk_index, source, content, org, vector_literal]
      )
    end

    :ok
  end

  def remove_embeddings(app, path, org \\ Acs.Org.current(), repo \\ Acs.Repo) do
    repo.query(
      "DELETE FROM #{@table_name} WHERE app = ? AND path = ? AND org = ?",
      [app, path, org]
    )

    :ok
  end

  def remove_all_for_app(app, org \\ Acs.Org.current(), repo \\ Acs.Repo) do
    repo.query("DELETE FROM #{@table_name} WHERE app = ? AND org = ?", [app, org])
    :ok
  end

  def search(query, opts \\ []) when is_binary(query) do
    limit = Keyword.get(opts, :limit, 20)
    app = Keyword.get(opts, :app)
    org = org_filter(opts)

    with {:ok, embedding} <- Acs.Memory.Embedding.embed_text(query) do
      if Pgvector.enabled?() do
        search_pg(embedding, org, app, limit)
      else
        search_sqlite(embedding, org, app, limit)
      end
    else
      {:error, reason} ->
        Logger.warning("[Specs.VectorSearch] Embedding failed: #{reason}")
        {:error, reason}
    end
  end

  defp search_pg(embedding, org, app, limit) do
    vector_literal = Pgvector.encode(embedding)
    {sql, params} = build_pg_search_sql(org, app, vector_literal, limit)

    case Acs.Repo.query(sql, params) do
      {:ok, %{rows: rows}} when is_list(rows) ->
        scored =
          Enum.map(rows, fn [id, chunk_app, chunk_path, chunk_index, source, content, similarity] ->
            %{
              id: id,
              app: chunk_app,
              path: chunk_path,
              chunk_index: chunk_index,
              source: source,
              content: content,
              similarity: Pgvector.to_float(similarity)
            }
          end)

        {:ok, scored}

      _ ->
        {:ok, []}
    end
  end

  defp build_pg_search_sql(nil, nil, vector_literal, limit) do
    {"""
     SELECT id, app, path, chunk_index, source, content,
            1 - (embedding <=> ($1::text)::vector) AS similarity
     FROM #{@table_name}
     ORDER BY embedding <=> ($1::text)::vector
     LIMIT $2
     """, [vector_literal, limit]}
  end

  defp build_pg_search_sql(nil, app, vector_literal, limit) do
    {"""
     SELECT id, app, path, chunk_index, source, content,
            1 - (embedding <=> ($1::text)::vector) AS similarity
     FROM #{@table_name}
     WHERE app = $2
     ORDER BY embedding <=> ($1::text)::vector
     LIMIT $3
     """, [vector_literal, app, limit]}
  end

  defp build_pg_search_sql(org, nil, vector_literal, limit) do
    {"""
     SELECT id, app, path, chunk_index, source, content,
            1 - (embedding <=> ($1::text)::vector) AS similarity
     FROM #{@table_name}
     WHERE org = $2
     ORDER BY embedding <=> ($1::text)::vector
     LIMIT $3
     """, [vector_literal, org, limit]}
  end

  defp build_pg_search_sql(org, app, vector_literal, limit) do
    {"""
     SELECT id, app, path, chunk_index, source, content,
            1 - (embedding <=> ($1::text)::vector) AS similarity
     FROM #{@table_name}
     WHERE org = $2 AND app = $3
     ORDER BY embedding <=> ($1::text)::vector
     LIMIT $4
     """, [vector_literal, org, app, limit]}
  end

  defp search_sqlite(embedding, org, app, limit) do
    {sql, params} = build_search_sql(org, app)

    case Acs.Repo.query(sql, params) do
      {:ok, %{rows: rows}} when is_list(rows) ->
        scored =
          rows
          |> Enum.map(fn [id, chunk_app, chunk_path, chunk_index, source, content, embedding_json] ->
            case Jason.decode(embedding_json) do
              {:ok, emb} ->
                %{
                  id: id,
                  app: chunk_app,
                  path: chunk_path,
                  chunk_index: chunk_index,
                  source: source,
                  content: content,
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

  defp build_search_sql(nil, nil) do
    {"SELECT id, app, path, chunk_index, source, content, embedding FROM #{@table_name}", []}
  end

  defp build_search_sql(nil, app) do
    {"SELECT id, app, path, chunk_index, source, content, embedding FROM #{@table_name} WHERE app = ?",
     [app]}
  end

  defp build_search_sql(org, nil) do
    {"SELECT id, app, path, chunk_index, source, content, embedding FROM #{@table_name} WHERE org = ?",
     [org]}
  end

  defp build_search_sql(org, app) do
    {"SELECT id, app, path, chunk_index, source, content, embedding FROM #{@table_name} WHERE org = ? AND app = ?",
     [org, app]}
  end

  def ensure_embeddings do
    unless Acs.Memory.Embedding.available?() do
      Logger.warning("[Specs.VectorSearch] Ollama not available, skipping")
      {:error, "Ollama unavailable"}
    else
      do_ensure_embeddings()
    end
  end

  defp do_ensure_embeddings do
    create_table()

    {:ok, entries} = Loader.load_all()
    existing = existing_chunk_ids()

    {embedded, failed} =
      Enum.reduce(entries, {0, 0}, fn entry, {emb_acc, fail_acc} ->
        chunks = chunk_entry(entry)

        unembedded_chunks =
          Enum.reject(chunks, fn chunk ->
            MapSet.member?(existing, chunk.id)
          end)

        if unembedded_chunks == [] do
          {emb_acc, fail_acc}
        else
          {chunk_emb, chunk_fail} =
            Enum.reduce(unembedded_chunks, {0, 0}, fn chunk, {ce, cf} ->
              case Acs.Memory.Embedding.embed_text(chunk.text) do
                {:ok, embedding} ->
                  upsert_chunk(
                    chunk.id,
                    chunk.app,
                    chunk.path,
                    chunk.chunk_index,
                    chunk.source,
                    chunk.content,
                    embedding
                  )

                  {ce + 1, cf}

                {:error, reason} ->
                  Logger.warning(
                    "[Specs.VectorSearch] Failed to embed chunk #{chunk.id}: #{reason}"
                  )

                  {ce, cf + 1}
              end
            end)

          {emb_acc + chunk_emb, fail_acc + chunk_fail}
        end
      end)

    stats = %{
      total_entries: length(entries),
      total_chunks: count_chunks(entries),
      existing: MapSet.size(existing),
      embedded: embedded,
      failed: failed
    }

    Logger.info(
      "[Specs.VectorSearch] ensure_embeddings: #{stats.total_entries} entries, #{stats.total_chunks} chunks, #{stats.existing} existing, #{stats.embedded} new, #{stats.failed} failed"
    )

    {:ok, stats}
  end

  defp count_chunks(entries) do
    Enum.reduce(entries, 0, fn entry, acc ->
      acc + length(chunk_entry(entry))
    end)
  end

  defp existing_chunk_ids do
    case Acs.Repo.query("SELECT id FROM #{@table_name}") do
      {:ok, %{rows: rows}} ->
        rows |> Enum.map(fn [id] -> id end) |> MapSet.new()

      {:error, _} ->
        MapSet.new()
    end
  end

  def chunk_entry(%Entry{} = entry) do
    id_prefix = "#{entry.app}/#{entry.id}"

    if entry.document_type && entry.content && String.length(entry.content) > 0 do
      chunk_document(entry, id_prefix)
    else
      chunk_spec(entry, id_prefix)
    end
  end

  defp chunk_document(%Entry{} = entry, id_prefix) do
    source = entry.source || Loader.file_path(entry.app, entry.id)
    paragraphs = split_paragraphs(entry.content || "")

    paragraphs
    |> group_into_chunks()
    |> Enum.with_index()
    |> Enum.map(fn {text, idx} ->
      chunk_id = "#{id_prefix}~chunk#{idx}"

      %{
        id: chunk_id,
        app: entry.app,
        path: entry.id,
        chunk_index: idx,
        source: source,
        content: text,
        text: build_chunk_text(%{
          title: entry.title,
          source: source,
          content: text
        })
      }
    end)
  end

  defp chunk_spec(%Entry{} = entry, id_prefix) do
    source = entry.source || Loader.file_path(entry.app, entry.id)

    sections = [
      {"purpose", entry.purpose},
      {"invariants", Enum.join(entry.invariants || [], "\n")},
      {"workflows", Enum.join(entry.workflows || [], "\n")},
      {"failure_modes", Enum.join(entry.failure_modes || [], "\n")},
      {"constraints", Enum.join(entry.constraints || [], "\n")},
      {"input_output", "#{entry.input || ""}\n#{entry.output || ""}"},
      {"transformation", entry.expected_transformation || ""}
    ]

    sections
    |> Enum.filter(fn {_name, text} -> is_binary(text) and String.trim(text) != "" end)
    |> Enum.with_index()
    |> Enum.map(fn {{name, text}, idx} ->
      chunk_id = "#{id_prefix}~#{name}"

      %{
        id: chunk_id,
        app: entry.app,
        path: entry.id,
        chunk_index: idx,
        source: source,
        content: text,
        text: build_chunk_text(%{
          title: entry.title,
          source: source,
          section: name,
          content: text
        })
      }
    end)
  end

  defp build_chunk_text(%{content: content} = meta) do
    meta_parts =
      [:title, :source, :section]
      |> Enum.map(fn key ->
        case Map.get(meta, key) do
          nil -> nil
          "" -> nil
          val -> "#{String.capitalize(to_string(key))}: #{val}"
        end
      end)
      |> Enum.reject(&is_nil/1)

    (meta_parts ++ [content])
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp split_paragraphs(content) do
    content
    |> String.split("\n\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp group_into_chunks(paragraphs) do
    group_into_chunks(paragraphs, [], [], 0)
  end

  defp group_into_chunks([], _current, acc, _word_count) do
    Enum.reverse(acc)
  end

  defp group_into_chunks([p | rest], current, acc, word_count) do
    p_word_count = count_words(p)
    new_count = word_count + p_word_count

    if new_count > @chunk_max_words and current != [] do
      chunk_text = Enum.join(current, "\n\n")
      remainder = merge_overlap(current, p)
      group_into_chunks(rest, remainder, [chunk_text | acc], count_words(Enum.join(remainder, "\n\n")))
    else
      group_into_chunks(rest, current ++ [p], acc, new_count)
    end
  end

  defp merge_overlap(current, next_paragraph) do
    overlap =
      current
      |> Enum.reverse()
      |> Enum.reduce({[], 0}, fn p, {acc, count} ->
        wc = count_words(p)
        if count + wc <= @chunk_overlap_words do
          {[p | acc], count + wc}
        else
          {acc, count}
        end
      end)
      |> elem(0)

    overlap ++ [next_paragraph]
  end

  defp count_words(text) when is_binary(text) do
    text |> String.split(~r/\s+/, trim: true) |> length()
  end

  defp count_words(_), do: 0

  defp org_filter(opts) do
    case Keyword.get(opts, :org) do
      org when is_binary(org) and org != "" -> org
      _ -> if Acs.Org.multi_tenant?(), do: Acs.Org.current(), else: nil
    end
  end
end
