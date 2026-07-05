defmodule Acs.Memory.Search do
  @moduledoc """
  Search and retrieval interface for the memory system.

  Provides both basic keyword search (via SQLite LIKE) and
  structured queries (by scope, kind, status, importance).

  Supports three search modes:
  - `"auto"` (default): hybrid search (semantic + lexical + scope + metadata) when
    embeddings are available, falling back to LIKE-based search
  - `"keyword"`: forces LIKE-based FTS search via Indexer
  - `"semantic"`: forces embedding-based vector search
  """

  require Logger

  @doc """
  Searches memories using the specified mode.

  Options:
  - `:mode` - "auto" (default), "keyword", or "semantic"
  - Other options passed through to the underlying search (scope_path, kind, limit, etc.)
  """
  def search(query, opts \\ []) do
    mode = Keyword.get(opts, :mode, "auto")

    case mode do
      "keyword" ->
        Acs.Memory.Indexer.search(query, opts)

      "semantic" ->
        search_semantic(query, opts)

      "auto" ->
        search_auto(query, opts)
    end
  end

  @doc """
  Like `search/2`, but also returns a scores map when hybrid/semantic results are available.

  Returns `{memories, scores_map}` where scores_map is `%{memory_id => float}`.
  When only keyword results are available, scores_map is empty.
  """
  def search_with_scores(query, opts \\ []) do
    mode = Keyword.get(opts, :mode, "auto")

    case mode do
      "keyword" ->
        {Acs.Memory.Indexer.search(query, opts), %{}}

      "semantic" ->
        search_semantic_with_scores(query, opts)

      "auto" ->
        search_auto_with_scores(query, opts)
    end
  end

  defp search_auto(query, opts) do
    if hybrid_available?() do
      hybrid_results = Acs.Memory.HybridSearch.search(query, opts)
      memory_ids = Enum.map(hybrid_results.results, & &1.memory_id)

      if memory_ids == [] do
        []
      else
        memories_map = Acs.Memory.Indexer.get_memories_by_ids(memory_ids)

        memory_ids
        |> Enum.map(fn id -> Map.get(memories_map, id) end)
        |> Enum.reject(&is_nil/1)
      end
    else
      Logger.warning("[Search] Hybrid search unavailable, falling back to keyword search")
      Acs.Memory.Indexer.search(query, opts)
    end
  end

  defp search_auto_with_scores(query, opts) do
    if hybrid_available?() do
      hybrid_results = Acs.Memory.HybridSearch.search(query, opts)
      memory_ids = Enum.map(hybrid_results.results, & &1.memory_id)

      if memory_ids == [] do
        {[], %{}}
      else
        memories_map = Acs.Memory.Indexer.get_memories_by_ids(memory_ids)
        scores_map = Map.new(hybrid_results.results, fn r -> {r.memory_id, r.total_score} end)

        memories =
          memory_ids
          |> Enum.map(fn id -> Map.get(memories_map, id) end)
          |> Enum.reject(&is_nil/1)

        {memories, scores_map}
      end
    else
      Logger.warning("[Search] Hybrid search unavailable, falling back to keyword search")
      {Acs.Memory.Indexer.search(query, opts), %{}}
    end
  end

  defp search_semantic(query, opts) do
    if Acs.Memory.Embedding.available?() do
      case Acs.Memory.Embedding.embed_text(query) do
        {:ok, embedding} ->
          limit = Keyword.get(opts, :limit, 20)
          similar = Acs.Memory.VectorIndex.search_similar(embedding, limit: limit)
          memory_ids = Enum.map(similar, & &1.memory_id)

          if memory_ids == [] do
            []
          else
            memories_map = Acs.Memory.Indexer.get_memories_by_ids(memory_ids)

            memory_ids
            |> Enum.map(fn id -> Map.get(memories_map, id) end)
            |> Enum.reject(&is_nil/1)
          end

        {:error, _reason} ->
          []
      end
    else
      Logger.warning("[Search] Embeddings unavailable for semantic search")
      []
    end
  end

  defp search_semantic_with_scores(query, opts) do
    if Acs.Memory.Embedding.available?() do
      case Acs.Memory.Embedding.embed_text(query) do
        {:ok, embedding} ->
          limit = Keyword.get(opts, :limit, 20)
          similar = Acs.Memory.VectorIndex.search_similar(embedding, limit: limit)

          memory_ids = Enum.map(similar, & &1.memory_id)

          if memory_ids == [] do
            {[], %{}}
          else
            memories_map = Acs.Memory.Indexer.get_memories_by_ids(memory_ids)
            scores_map = Map.new(similar, fn s -> {s.memory_id, s.similarity} end)

            memories =
              memory_ids
              |> Enum.map(fn id -> Map.get(memories_map, id) end)
              |> Enum.reject(&is_nil/1)

            {memories, scores_map}
          end

        {:error, _reason} ->
          {[], %{}}
      end
    else
      Logger.warning("[Search] Embeddings unavailable for semantic search")
      {[], %{}}
    end
  end

  defp hybrid_available? do
    Code.ensure_loaded?(Acs.Memory.HybridSearch) &&
      function_exported?(Acs.Memory.HybridSearch, :search, 2) &&
      Acs.Memory.Embedding.available?()
  end

  @doc """
  Lists memories with structured filters.
  """
  def list(opts \\ []) do
    Acs.Memory.Indexer.list_memories(opts)
  end

  @doc """
  Gets a single memory by ID.
  """
  def get(memory_id) do
    Acs.Memory.Indexer.get_memory(memory_id)
  end

  @doc """
  Finds memories relevant to a given context string and scope.
  Uses simple keyword matching and scope overlap.
  Returns top results ranked by relevance.
  """
  def find_relevant(context, opts \\ []) do
    keywords = extract_keywords(context)

    memories = search(keywords, opts)

    approved = Enum.filter(memories, fn m -> m.status == "approved" end)

    Enum.sort_by(approved, & &1.importance, :desc)
  end

  defp extract_keywords(context) when is_binary(context) do
    context
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    |> Enum.reject(fn w -> String.length(w) < 3 end)
    |> Enum.reject(fn w -> w in ~w(the and for are but not you all can had her was has had) end)
    |> Enum.take(10)
    |> Enum.join(" ")
  end

  defp extract_keywords(_), do: ""
end
