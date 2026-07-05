defmodule Acs.MCP.Tools.QueryAgent do
  @moduledoc """
  The `ask` tool — structured-param query interface for collaborators.

  Accepts filters and returns a formatted markdown summary of matched
  memories, documents, and agent status. No server-side NL parsing —
  the client AI translates the human's natural language into these
  structured parameters.

  ## Parameters

  - `kind` — memory kind filter (context, status, work_note, activity, ...)
  - `team` — team scope filter
  - `project` — project scope filter
  - `content_query` — free-text search string for memories and documents
  - `document_type` — document type filter (policy, process, guideline, reference, spec)
  - `limit` — max results per category (default 10)
  - `include_documents` — whether to search documents too (default true)
  - `include_agent_status` — whether to include agent presence (default true)
  """

  require Logger

  @default_limit 10
  @max_limit 50

  @doc """
  Executes an `ask` query against memories, documents, and agent status.
  """
  def ask(args) do
    limit = clamp_limit(args["limit"])
    abac_opts = extract_abac(args)

    results = [
      search_memories(args, abac_opts, limit),
      search_documents(args, abac_opts, limit),
      agent_status(args)
    ]

    {:ok, format_response(args, results)}
  end

  defp search_memories(args, abac_opts, limit) do
    query = args["content_query"]
    kind = args["kind"]
    team = args["team"]
    project = args["project"]

    search_opts =
      abac_opts
      |> Keyword.merge(limit: limit)
      |> maybe_put(:kind, kind)

    case {query, team, project} do
      {q, nil, nil} when is_binary(q) and q != "" ->
        mems = Acs.Memory.Search.search(q, search_opts)
        {:memory_results, mems}

      {nil, nil, nil} ->
        mems = Acs.Memory.Search.list(search_opts)
        {:memory_results, mems}

      _ ->
        list_opts = search_opts
        list_opts = if team, do: Keyword.put(list_opts, :team, team), else: list_opts
        list_opts = if project, do: Keyword.put(list_opts, :project, project), else: list_opts
        mems = Acs.Memory.Indexer.list_memories(list_opts)
        {:memory_results, mems}
    end
  end

  defp search_documents(args, abac_opts, limit) do
    if args["include_documents"] == false do
      {:document_results, []}
    else
      query = args["content_query"]
      doc_type = args["document_type"]

      entries =
        cond do
          is_binary(query) and query != "" ->
            case Acs.Specs.Search.search(query) do
              {:ok, results} -> results
              _ -> []
            end

          is_binary(doc_type) and doc_type != "" ->
            case Acs.Specs.Search.search("") do
              {:ok, results} ->
                results
                |> Enum.filter(fn e -> is_entry_match?(e, doc_type) end)
                |> Enum.take(limit)

              _ ->
                []
            end

          true ->
            case Acs.Specs.Search.search("") do
              {:ok, results} -> Enum.take(results, limit)
              _ -> []
            end
        end

      {:document_results, Acs.Abac.filter(entries, Acs.Abac.from_keyword(abac_opts))}
    end
  end

  defp agent_status(args) do
    if args["include_agent_status"] == false do
      {:agent_status, []}
    else
      all_status = Acs.Acs.get_present_status()

      agents =
        all_status
        |> Enum.map(fn {agent_id, s} ->
          %{
            agent_id: agent_id,
            purpose: if(is_map(s), do: Map.get(s, :purpose), else: "unknown"),
            current_task: if(is_map(s), do: Map.get(s, :current_task_id))
          }
        end)

      {:agent_status, agents}
    end
  end

  defp format_response(_args, results) do
    mems = Keyword.get(results, :memory_results) || []
    docs = Keyword.get(results, :document_results) || []
    agents = Keyword.get(results, :agent_status) || []

    sections =
      []
      |> maybe_prepend(format_memories_section(mems))
      |> maybe_prepend(format_documents_section(docs))
      |> maybe_prepend(format_status_section(agents))

    %{
      response:
        if(sections == [],
          do: "No results found for your query.",
          else: Enum.join(sections, "\n")
        ),
      summary: %{
        memory_count: length(mems || []),
        document_count: length(docs || []),
        agent_count: length(agents || [])
      }
    }
  end

  defp format_memories_section([]), do: nil
  defp format_memories_section(nil), do: nil

  defp format_memories_section(mems) do
    items =
      mems
      |> Enum.take(@max_limit)
      |> Enum.map(fn m ->
        id = if is_struct(m, Acs.Memory.Schema), do: m.id, else: Map.get(m, :id)
        title = if is_struct(m, Acs.Memory.Schema), do: m.title, else: Map.get(m, :title)
        kind = if is_struct(m, Acs.Memory.Schema), do: m.kind, else: Map.get(m, :kind)
        status = if is_struct(m, Acs.Memory.Schema), do: m.status, else: Map.get(m, :status)
        team_tag = if is_struct(m, Acs.Memory.Schema), do: m.team, else: Map.get(m, :team)

        meta = [kind, status]
        meta = if team_tag, do: meta ++ ["team:#{team_tag}"], else: meta

        "- **#{title}** (`#{Enum.join(meta, ", ")}`) — #{id}"
      end)

    "## Memories (#{length(mems)})\n\n#{Enum.join(items, "\n")}"
  end

  defp format_documents_section([]), do: nil
  defp format_documents_section(nil), do: nil

  defp format_documents_section(docs) do
    items =
      docs
      |> Enum.take(@max_limit)
      |> Enum.map(fn d ->
        title = if is_struct(d, Acs.Specs.Entry), do: d.title, else: Map.get(d, :title)

        doc_type =
          if is_struct(d, Acs.Specs.Entry), do: d.document_type, else: Map.get(d, :document_type)

        app = if is_struct(d, Acs.Specs.Entry), do: d.app, else: Map.get(d, :app)
        id = if is_struct(d, Acs.Specs.Entry), do: d.id, else: Map.get(d, :id)

        type_str = if doc_type, do: doc_type, else: "spec"
        app_str = if app, do: " (#{app})", else: ""

        "- **#{title}** (`#{type_str}#{app_str}`) — #{id}"
      end)

    "## Documents (#{length(docs)})\n\n#{Enum.join(items, "\n")}"
  end

  defp format_status_section([]), do: nil
  defp format_status_section(nil), do: nil

  defp format_status_section(agents) do
    items =
      agents
      |> Enum.map(fn a ->
        purpose = a[:purpose] || "unknown"
        task = a[:current_task]
        task_str = if task, do: " (task: #{task})", else: ""
        "- **#{a[:agent_id]}**: #{purpose}#{task_str}"
      end)

    "## Agent Status (#{length(agents)})\n\n#{Enum.join(items, "\n")}"
  end

  defp extract_abac(args) do
    []
    |> maybe_put(:allowed_teams, args["_auth_allowed_teams"])
    |> maybe_put(:allowed_projects, args["_auth_allowed_projects"])
    |> maybe_put(:agent_role, args["_auth_role"])
  end

  defp clamp_limit(nil), do: @default_limit
  defp clamp_limit(n) when is_integer(n) and n > @max_limit, do: @max_limit
  defp clamp_limit(n) when is_integer(n) and n < 1, do: @default_limit
  defp clamp_limit(n) when is_integer(n), do: n
  defp clamp_limit(_), do: @default_limit

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, value), do: Keyword.put(kw, key, value)

  defp maybe_prepend(list, nil), do: list
  defp maybe_prepend(list, item), do: list ++ [item]

  defp is_entry_match?(%Acs.Specs.Entry{document_type: dt}, type), do: dt == type
  defp is_entry_match?(map, type) when is_map(map), do: Map.get(map, :document_type) == type
  defp is_entry_match?(_, _), do: false
end
