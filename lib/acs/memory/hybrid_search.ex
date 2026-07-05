defmodule Acs.Memory.HybridSearch do
  @moduledoc """
  Hybrid search combining lexical, semantic, scope, and metadata signals.

  Scoring components:
  - Lexical: text match score (0.0-1.0) based on LIKE matching
  - Semantic: vector similarity from Ollama embeddings
  - Scope: exact=1.0, parent=0.7, sibling=0.4
  - Metadata: importance (0-5) normalized + status (approved=1.0, others lower)

  Final score = 0.4*semantic + 0.3*lexical + 0.2*scope + 0.1*metadata
  """

  alias Acs.Memory.{Indexer, VectorIndex, Embedding}

  @default_limit 20

  @doc """
  Performs hybrid search across memory corpus.

  Options:
  - `:query` - search query string
  - `:scope` - filter by scope prefix
  - `:limit` - max results (default 20)
  - `:semantic_weight` - weight for semantic score (default 0.4)
  - `:lexical_weight` - weight for lexical score (default 0.3)
  - `:scope_weight` - weight for scope score (default 0.2)
  - `:metadata_weight` - weight for metadata score (default 0.1)
  """
  def search(query, opts \\ []) when is_binary(query) do
    limit = Keyword.get(opts, :limit, @default_limit)
    scope = Keyword.get(opts, :scope, nil)
    team_filter = Keyword.get(opts, :team_filter)
    project_filter = Keyword.get(opts, :project_filter)

    query_embedding = get_query_embedding(query)

    lexical_opts =
      opts
      |> Keyword.put(:limit, limit * 2)
      |> maybe_put_scope_path(scope)

    lexical_results = Indexer.search(query, lexical_opts)

    all_memory_ids = lexical_results |> Enum.map(& &1.id) |> Enum.uniq()

    semantic_scores = fetch_semantic_scores(query_embedding, all_memory_ids)

    scored_results =
      lexical_results
      |> Enum.map(fn memory ->
        semantic = Map.get(semantic_scores, memory.id, 0.0)
        lexical = compute_lexical_score(memory, query)
        scope_score = compute_scope_score(memory.scope_path, scope)

        meta =
          compute_metadata_score(memory, team_filter: team_filter, project_filter: project_filter)

        total =
          0.4 * semantic +
            0.3 * lexical +
            0.2 * scope_score +
            0.1 * meta

        %{
          memory_id: memory.id,
          title: memory.title,
          scope_path: memory.scope_path,
          kind: memory.kind,
          status: memory.status,
          importance: memory.importance,
          scores: %{
            semantic: semantic,
            lexical: lexical,
            scope: scope_score,
            metadata: meta
          },
          total_score: Float.round(total, 4)
        }
      end)
      |> Enum.sort_by(& &1.total_score, :desc)
      |> Enum.take(limit)

    %{query: query, results: scored_results, total: length(scored_results)}
  end

  defp get_query_embedding(query) do
    case Embedding.embed_text(query) do
      {:ok, embedding} -> embedding
      _ -> nil
    end
  end

  defp fetch_semantic_scores(nil, _), do: %{}

  defp fetch_semantic_scores(embedding, memory_ids) do
    all_similar = VectorIndex.search_similar(embedding, limit: 100)

    memory_ids
    |> Enum.map(fn id ->
      score =
        Enum.find_value(all_similar, 0.0, fn %{memory_id: mid, similarity: sim} ->
          if mid == id, do: sim
        end)

      {id, score}
    end)
    |> Enum.into(%{})
  end

  defp compute_lexical_score(memory, query) do
    query_lower = String.downcase(query)

    title_match = String.contains?(String.downcase(memory.title), query_lower)
    content_match = String.contains?(String.downcase(memory.content || ""), query_lower)
    summary_match = String.contains?(String.downcase(memory.summary || ""), query_lower)

    cond do
      title_match && summary_match -> 0.9
      title_match -> 0.7
      content_match -> 0.5
      summary_match -> 0.4
      true -> 0.0
    end
  end

  defp compute_scope_score(_scope_path, nil), do: 0.5

  defp compute_scope_score(scope_path, filter_scope) do
    cond do
      scope_path == filter_scope ->
        1.0

      String.starts_with?(scope_path, filter_scope <> "/") ->
        0.7

      String.starts_with?(filter_scope, scope_path) ->
        0.7

      true ->
        scope_segments = String.split(scope_path, "/")
        filter_segments = String.split(filter_scope, "/")

        if scope_segments != [] and filter_segments != [] and
             hd(scope_segments) == hd(filter_segments) do
          0.4
        else
          0.1
        end
    end
  end

  defp compute_metadata_score(memory, opts) do
    importance_score = memory.importance / 5.0

    status_score =
      case memory.status do
        "approved" -> 1.0
        "proposed" -> 0.7
        "archived" -> 0.3
        _ -> 0.5
      end

    team_bonus = compute_team_project_bonus(memory, opts)

    0.6 * importance_score + 0.4 * status_score + team_bonus
  end

  defp compute_team_project_bonus(memory, opts) do
    team_filter = Keyword.get(opts, :team_filter)
    project_filter = Keyword.get(opts, :project_filter)

    cond do
      team_filter && memory.team == team_filter -> 0.05
      project_filter && memory.project == project_filter -> 0.05
      memory.team || memory.project -> 0.02
      true -> 0.0
    end
  end

  defp maybe_put_scope_path(opts, nil), do: opts
  defp maybe_put_scope_path(opts, scope), do: Keyword.put(opts, :scope_path, scope)
end
