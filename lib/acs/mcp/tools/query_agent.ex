defmodule Acs.MCP.Tools.QueryAgent do
  @moduledoc """
  The `ask` tool — structured-param query interface for collaborators.

  Accepts filters and returns a formatted markdown summary of matched
  memories, documents, skills, and agent status. No server-side NL parsing —
  the client AI translates the human's natural language into these
  structured parameters.

  ## Parameters

  - `kind` — memory kind filter (context, status, work_note, activity, ...)
  - `team` — team scope filter
  - `project` — project scope filter
  - `content_query` — free-text search string for memories, documents, and skills
  - `document_type` — document type filter (spec, knowledge, project, marketing, deliverable, policy, process, guideline, reference)
  - `status` — memory status filter (default: approved; use "all" for no filter)
  - `limit` — max results per category (default 10)
  - `include_documents` — whether to search documents too (default true)
  - `include_skills` — whether to search skills too (default true)
  - `include_agent_status` — whether to include agent presence (default true)
  """

  require Logger

  alias Acs.Skills.Store

  @default_limit 10
  @max_limit 50
  @default_skill_min_score 0.45

  @doc """
  Executes an `ask` query against memories, documents, skills, and agent status.

  Always scoped to `Acs.Org.current/0` (passed explicitly into Tasks and search opts).
  """
  def ask(args) do
    limit = clamp_limit(args["limit"])
    abac_opts = extract_abac(args)
    org = Acs.Org.current()
    embedding = maybe_embed_query(args["content_query"])

    search_opts =
      abac_opts
      |> Keyword.put(:org, org)
      |> maybe_put(:embedding, embedding)

    # Capture org for Task processes (Org.current/0 is process-local).
    mem_task =
      Task.async(fn ->
        Acs.Org.with_current(org, fn -> search_memories(args, search_opts, limit) end)
      end)

    doc_task =
      Task.async(fn ->
        Acs.Org.with_current(org, fn -> search_documents(args, search_opts, limit) end)
      end)

    skill_task =
      Task.async(fn ->
        Acs.Org.with_current(org, fn -> search_skills(args, search_opts, limit) end)
      end)

    agents = agent_status(args)

    results = [
      Task.await(mem_task, 35_000),
      Task.await(doc_task, 35_000),
      Task.await(skill_task, 35_000),
      agents
    ]

    {:ok, format_response(args, results)}
  end

  # One Ollama call shared by memory + document + skill hybrid search.
  defp maybe_embed_query(query) when is_binary(query) and query != "" do
    case Acs.Memory.Embedding.embed_text(query) do
      {:ok, embedding} -> embedding
      _ -> nil
    end
  end

  defp maybe_embed_query(_), do: nil

  defp search_memories(args, search_opts, limit) do
    query = args["content_query"]
    kind = args["kind"]
    status = Acs.Memory.Search.resolve_status_filter(args["status"])
    team = args["team"]
    project = args["project"]

    opts =
      search_opts
      |> Keyword.merge(limit: limit)
      |> maybe_put(:kind, kind)
      |> maybe_put(:status, status)

    case {query, team, project} do
      {q, nil, nil} when is_binary(q) and q != "" ->
        mems = Acs.Memory.Search.search(q, opts)
        {:memory_results, mems}

      {nil, nil, nil} ->
        mems = Acs.Memory.Search.list(opts)
        {:memory_results, mems}

      _ ->
        list_opts = opts
        list_opts = if team, do: Keyword.put(list_opts, :team, team), else: list_opts
        list_opts = if project, do: Keyword.put(list_opts, :project, project), else: list_opts
        mems = Acs.Memory.Indexer.list_memories(list_opts)
        {:memory_results, mems}
    end
  end

  defp search_documents(args, search_opts, limit) do
    if args["include_documents"] == false do
      {:document_results, []}
    else
      query = args["content_query"]
      doc_type = args["document_type"]
      # Specs search accepts :embedding / :org from the shared ask opts.
      spec_opts = Keyword.take(search_opts, [:embedding, :org])

      entries =
        cond do
          is_binary(query) and query != "" ->
            case Acs.Specs.Search.search(query, spec_opts) do
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

      {:document_results, Acs.Abac.filter(entries, Acs.Abac.from_keyword(search_opts))}
    end
  end

  defp search_skills(args, search_opts, limit) do
    if args["include_skills"] == false do
      {:skill_results, []}
    else
      query = args["content_query"]

      skills =
        cond do
          is_binary(query) and query != "" ->
            related_skills(query, search_opts, limit)

          true ->
            []
        end

      {:skill_results, skills}
    end
  end

  # Prefer org-scoped vector hits with the shared embedding; fall back to lexical.
  defp related_skills(query, search_opts, limit) do
    vector_opts =
      search_opts
      |> Keyword.take([:embedding, :org])
      |> Keyword.put(:limit, limit)

    case Acs.Skills.VectorSearch.search(query, vector_opts) do
      {:ok, scored} when is_list(scored) and scored != [] ->
        scored
        |> Enum.filter(&(&1.similarity >= @default_skill_min_score))
        |> Enum.take(limit)
        |> Enum.map(&enrich_skill/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        Store.search_skills(query)
        |> Enum.take(limit)
        |> Enum.map(&skill_summary/1)
    end
  end

  defp enrich_skill(%{skill_name: name, similarity: sim}) do
    case Store.get_skill(name) do
      nil ->
        %{name: name, description: nil, tags: [], similarity: Float.round(sim, 4)}

      skill ->
        skill_summary(skill) |> Map.put(:similarity, Float.round(sim, 4))
    end
  end

  defp skill_summary(skill) do
    %{
      name: skill.name,
      description: skill.description,
      tags: skill.tags || [],
      when_to_use: Map.get(skill, :when_to_use) || Map.get(skill, "when_to_use")
    }
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
    skills = Keyword.get(results, :skill_results) || []
    agents = Keyword.get(results, :agent_status) || []

    sections =
      []
      |> maybe_prepend(format_memories_section(mems))
      |> maybe_prepend(format_documents_section(docs))
      |> maybe_prepend(format_skills_section(skills))
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
        skill_count: length(skills || []),
        agent_count: length(agents || [])
      },
      relevant_skills: skills
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

  defp format_skills_section([]), do: nil
  defp format_skills_section(nil), do: nil

  defp format_skills_section(skills) do
    items =
      skills
      |> Enum.take(@max_limit)
      |> Enum.map(fn s ->
        name = s[:name] || s["name"]
        desc = s[:description] || s["description"] || ""
        tags = s[:tags] || s["tags"] || []
        tag_str = if tags == [], do: "", else: " [#{Enum.join(tags, ", ")}]"
        desc_str = if desc == "" or is_nil(desc), do: "", else: " — #{desc}"
        "- **#{name}**#{tag_str}#{desc_str}"
      end)

    "## Related Skills (#{length(skills)})\n\n#{Enum.join(items, "\n")}\n\nUse `skill_get(name:)` to load a procedure."
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
    |> maybe_put(:agent_id, args["_auth_agent_id"])
    |> maybe_put(:audience, args["_auth_audience"])
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
