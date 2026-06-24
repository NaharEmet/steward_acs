defmodule Acs.Memory.Search do
  @moduledoc """
  Search and retrieval interface for the memory system.

  Provides both basic keyword search (via SQLite LIKE) and
  structured queries (by scope, kind, status, importance).
  """

  require Logger

  @doc """
  Searches memories by keyword across title, summary, and content.
  Uses hybrid search (semantic + lexical + scope + metadata) when embeddings are available,
  falling back to basic LIKE-based search through Indexer.
  """
  def search(query, opts \\ []) do
    if Code.ensure_loaded?(Acs.Memory.HybridSearch) &&
         function_exported?(Acs.Memory.HybridSearch, :search, 2) &&
         Acs.Memory.Embedding.available?() do
      # Use hybrid search for better results
      hybrid_results = Acs.Memory.HybridSearch.search(query, opts)
      memory_ids = Enum.map(hybrid_results.results, & &1.memory_id)

      if memory_ids == [] do
        []
      else
        memories_map = Acs.Memory.Indexer.get_memories_by_ids(memory_ids)

        # Return in hybrid score order
        memory_ids
        |> Enum.map(fn id -> Map.get(memories_map, id) end)
        |> Enum.reject(&is_nil/1)
      end
    else
      Logger.warning("[Search] Hybrid search unavailable, falling back to keyword search")
      Acs.Memory.Indexer.search(query, opts)
    end
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
