defmodule Acs.Memory.HybridSearch do
  @moduledoc """
  Hybrid search combining lexical, semantic, scope, and metadata signals.

  Scoring components:
  - Lexical: text match score (0.0-1.0) based on LIKE matching
  - Semantic: vector similarity from Ollama embeddings
  - Scope: exact=1.0, parent=0.7, sibling=0.4
  - Metadata: importance (0-5) normalized + status (approved=1.0, others lower)
  - Audience: exact match=1.0, legacy (nil)=0.5, different=0.2

  Final score = 0.30*semantic + 0.20*lexical + 0.15*scope + 0.10*metadata + 0.25*audience
  """

  alias Acs.Memory.{Indexer, VectorIndex, Embedding}

  @default_limit 20
  @default_min_score 0.41

  @doc """
  Performs hybrid search across memory corpus.

  Options:
  - `:query` - search query string
  - `:scope` - filter by scope prefix
  - `:audience` - requesting audience ("coding" | "chat") for audience-weighted scoring
  - `:limit` - max results (default 20)
  - `:semantic_weight` - weight for semantic score (default 0.30)
  - `:lexical_weight` - weight for lexical score (default 0.20)
  - `:scope_weight` - weight for scope score (default 0.15)
  - `:metadata_weight` - weight for metadata score (default 0.10)
  - `:audience_weight` - weight for audience score (default 0.25)
  - `:embedding` - precomputed query embedding (skips Ollama when provided)
  - `:org` - tenant filter for vector search
  """
  def search(query, opts \\ []) when is_binary(query) do
    limit = Keyword.get(opts, :limit, @default_limit)
    min_score = Keyword.get(opts, :min_score, @default_min_score)
    scope = Keyword.get(opts, :scope, nil)
    audience = Keyword.get(opts, :audience)
    team_filter = Keyword.get(opts, :team_filter)
    project_filter = Keyword.get(opts, :project_filter)
    org = Keyword.get(opts, :org) || Acs.Org.current()

    query_embedding = get_query_embedding(query, opts)

    lexical_opts =
      opts
      |> Keyword.put(:limit, limit * 2)
      |> Keyword.put(:org, org)
      |> maybe_put_scope_path(scope)

    # Lexical DB scan and vector ANN in parallel once embedding is ready.
    {lexical_results, semantic_scores} =
      run_lexical_and_semantic(query, lexical_opts, query_embedding, org, limit)

    scored_results =
      lexical_results
      |> Enum.map(fn memory ->
        semantic = Map.get(semantic_scores, memory.id, 0.0)
        lexical = compute_lexical_score(memory, query)
        scope_score = compute_scope_score(memory.scope_path, scope)

        meta =
          compute_metadata_score(memory, team_filter: team_filter, project_filter: project_filter)

        aud = compute_audience_score(memory.audience, audience)

        total =
          0.30 * semantic +
            0.20 * lexical +
            0.15 * scope_score +
            0.10 * meta +
            0.25 * aud

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
            metadata: meta,
            audience: aud
          },
          total_score: Float.round(total, 4)
        }
      end)
      |> Enum.filter(&(&1.total_score >= min_score))
      |> Enum.sort_by(& &1.total_score, :desc)
      |> Enum.take(limit)

    %{query: query, results: scored_results, total: length(scored_results)}
  end

  # Prefer embedding from opts; fall back to embedding the query string.
  defp get_query_embedding(query, opts) when is_binary(query) do
    case Keyword.get(opts, :embedding) do
      emb when is_list(emb) and emb != [] ->
        emb

      _ ->
        case Embedding.embed_text(query) do
          {:ok, embedding} -> embedding
          _ -> nil
        end
    end
  end

  defp run_lexical_and_semantic(query, lexical_opts, nil, _org, _limit) do
    {Indexer.search(query, lexical_opts), %{}}
  end

  defp run_lexical_and_semantic(query, lexical_opts, embedding, org, limit) do
    vector_limit = max(limit * 10, 100)

    lexical_task =
      Task.async(fn ->
        Acs.Org.with_current(org, fn -> Indexer.search(query, lexical_opts) end)
      end)

    semantic_task =
      Task.async(fn ->
        Acs.Org.with_current(org, fn ->
          VectorIndex.search_similar(embedding, limit: vector_limit, org: org)
          |> Map.new(fn %{memory_id: id, similarity: sim} -> {id, sim} end)
        end)
      end)

    lexical_results = Task.await(lexical_task, 15_000)
    semantic_scores = Task.await(semantic_task, 15_000)
    {lexical_results, semantic_scores}
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

  defp compute_audience_score(_mem_audience, nil), do: 0.5

  defp compute_audience_score(mem_audience, req_audience) do
    mem = mem_audience && String.trim(mem_audience)
    req = req_audience && String.trim(req_audience)

    cond do
      mem == req -> 1.0
      is_nil(mem) or mem == "" -> 0.5
      true -> 0.2
    end
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
