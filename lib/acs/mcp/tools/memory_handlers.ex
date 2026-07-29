defmodule Acs.MCP.Tools.MemoryHandlers do
  @moduledoc """
  Handles knowledge memory MCP tools for the ACS memory system.

  ## Purpose

  Implements handler functions for the knowledge memory lifecycle:
  saving memories (with duplicate detection via exact ID, semantic
  similarity, and lexical title match), listing/searching memories,
  updating memory status, and generating guidance packets.

  ## Key Functions

  - `save_memory/1` — Creates a new memory with multi-layer duplicate
    detection (exact ID, semantic vector similarity, lexical title match)
  - `query_memories/1` — Unified query tool: if `query` is provided does
    hybrid search (semantic + FTS); otherwise lists memories with filters
  - `set_memory_status/1` — Updates memory status (approved, rejected,
    stale, deprecated)
  - `generate_guidance_packet/1` — Generates structured guidance for a
    scope path or task ID

  """
  require Logger

  def save_memory(args) do
    ctx = Acs.Abac.from_args(args)
    org = Acs.Org.current()

    creator_id = args["_auth_attribution"] || args["_auth_agent_id"] || Acs.Org.developer_name()

    creator_type =
      if is_binary(creator_id) and String.contains?(creator_id, "@"), do: "user", else: "developer"

    args = normalize_about_args(args)
    {:ok, intake} = Acs.Memory.Intake.review(args)
    args = merge_intake_into_args(args, intake)

    person = resolve_about_person_record(args, org)

    cond do
      about_entity?(args) and not explicit_visibility?(args) ->
        {:ok, scope_choice_payload(args, person, intake)}

      blocking_intake?(intake, args) ->
        {:ok, intake_questions_payload(args, intake)}

      true ->
        do_save_memory(args, ctx, org, creator_id, creator_type, person, intake)
    end
  end

  defp do_save_memory(args, ctx, org, creator_id, creator_type, person, intake) do
    kind = args["kind"]
    title = args["title"]
    content = args["content"]
    scope_path = args["scope_path"]
    tags = args["tags"] || []
    triggers = args["triggers"] || []
    importance = args["importance"] || 3
    summary = args["summary"]
    failure_modes = args["failure_modes"] || []
    team = args["team"]
    project = args["project"]

    {visibility, tags} = resolve_visibility_and_tags(args, person, tags)

    memory_map =
      %{
        "id" => Acs.Memory.generate_id(%{"kind" => kind, "title" => title}),
        "kind" => kind,
        "title" => title,
        "summary" => summary,
        "content" => content,
        "scope_path" => scope_path,
        "importance" => importance,
        "audience" => args["_auth_audience"],
        "tags" => tags,
        "triggers" => triggers,
        "failure_modes" => failure_modes,
        "created_by" => %{
          "type" => creator_type,
          "id" => creator_id,
          "org" => org
        },
        "org" => org,
        "team" => team,
        "project" => project,
        "visibility" => visibility
      }
      |> Acs.MCP.MemoryProvenance.enrich_memory_map(args)

    memory_map =
      case Acs.Abac.memory_status_for_write(ctx, memory_map) do
        nil -> memory_map
        status -> Map.put(memory_map, "status", status)
      end

    with :ok <- Acs.Abac.validate_write(ctx, memory_map),
         :ok <- Acs.Memory.validate(memory_map) do
      memory = Acs.Memory.new(memory_map)

      case do_save_with_validation(memory, memory_map) do
        {:ok, result} ->
          {:ok, maybe_attach_sensitive_note(result, intake, visibility)}

        other ->
          other
      end
    else
      {:error, reasons} when is_list(reasons) ->
        {:error, "Validation failed: #{Enum.join(reasons, "; ")}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def query_memories(args) do
    query = args["query"]
    mode = args["mode"] || "auto"
    min_relevance = args["min_relevance"]

    base_opts = [
      scope_path: args["scope_path"] || args["scope"],
      kind: args["kind"],
      status: Acs.Memory.Search.resolve_status_filter(args["status"]),
      limit: args["limit"] || 50,
      org: Acs.Org.current(),
      allowed_teams: args["_auth_allowed_teams"],
      allowed_projects: args["_auth_allowed_projects"],
      agent_role: args["_auth_role"],
      agent_id: args["_auth_agent_id"],
      audience: args["_auth_audience"]
    ]

    if query && query != "" do
      search_opts = Keyword.put(base_opts, :mode, mode)

      {memories, scores} = Acs.Memory.Search.search_with_scores(query, search_opts)

      result =
        memories
        |> Enum.map(fn m ->
          %{
            id: m.id,
            kind: m.kind,
            status: m.status,
            title: m.title,
            summary: m.summary,
            scope_path: m.scope_path,
            importance: m.importance,
            content: String.slice(m.content || "", 0, 500),
            relevance: Map.get(scores, m.id),
            created_by: decode_created_by(m.created_by_json),
            visibility: m.visibility
          }
        end)
        |> maybe_filter_by_relevance(min_relevance)

      {:ok, %{memories: result, count: length(result), mode: mode}}
    else
      memories = Acs.Memory.Search.list(base_opts)

      result =
        Enum.map(memories, fn m ->
          %{
            id: m.id,
            kind: m.kind,
            status: m.status,
            title: m.title,
            scope_path: m.scope_path,
            importance: m.importance,
            created_at: m.created_at,
            updated_at: m.updated_at,
            created_by: decode_created_by(m.created_by_json),
            visibility: m.visibility
          }
        end)

      {:ok, %{memories: result, count: length(result)}}
    end
  end

  defp maybe_filter_by_relevance(results, nil), do: results

  defp maybe_filter_by_relevance(results, min) when is_number(min) do
    Enum.filter(results, fn r -> r[:relevance] != nil && r[:relevance] >= min end)
  end

  defp maybe_filter_by_relevance(results, _), do: results

  def set_memory_status(args) do
    memory_id = args["memory_id"]
    status = args["status"]

    valid_statuses = ~w(approved rejected stale deprecated)
    chat? = Acs.MCP.Audience.normalize(args["_auth_audience"]) == :chat

    cond do
      status not in valid_statuses ->
        {:error, "Invalid status '#{status}'. Must be one of: #{Enum.join(valid_statuses, ", ")}"}

      chat? and status not in ~w(stale deprecated) ->
        {:error,
         "Chat can only mark memories stale or deprecated. Use status: \"stale\" (outdated) or \"deprecated\" (retired)."}

      true ->
        case Acs.Memory.Indexer.update_status(memory_id, status, Acs.Org.current()) do
          {:ok, schema} ->
            attrs =
              case status do
                "approved" ->
                  %{
                    "status" => "approved",
                    "verification" => %{
                      "status" => "approved",
                      "approved_by" => args["notes"] || "human",
                      "approved_at" => DateTime.utc_now() |> DateTime.to_iso8601()
                    }
                  }

                "rejected" ->
                  %{
                    "status" => "rejected",
                    "verification" => %{
                      "status" => "rejected",
                      "rejected_by" => args["notes"] || "human",
                      "rejected_at" => DateTime.utc_now() |> DateTime.to_iso8601()
                    }
                  }

                "stale" ->
                  %{
                    "status" => "stale",
                    "revalidation" => %{
                      "reason" => args["notes"] || "No reason provided",
                      "marked_at" => DateTime.utc_now() |> DateTime.to_iso8601()
                    }
                  }

                "deprecated" ->
                  %{
                    "status" => "deprecated",
                    "revalidation" => %{
                      "reason" => args["notes"] || "No reason provided",
                      "marked_at" => DateTime.utc_now() |> DateTime.to_iso8601()
                    }
                  }
              end

            result =
              schema
              |> Acs.Memory.Indexer.schema_to_memory_attrs()
              |> Map.merge(attrs)
              |> Acs.Memory.new()
              |> Acs.Memory.Loader.save()

            case result do
              :ok ->
                {:ok, %{status: status, memory_id: memory_id, message: "Memory #{status}"}}

              {:error, reason} ->
                {:error, "Failed to save memory status: #{inspect(reason)}"}
            end

          {:error, reason} ->
            {:error, "Failed to update memory status: #{inspect(reason)}"}
        end
    end
  end

  def generate_guidance_packet(args) do
    scope_path = args["scope_path"] || args["scope"]
    task_id = args["task_id"]
    allowed_teams = args["_auth_allowed_teams"]
    allowed_projects = args["_auth_allowed_projects"]
    agent_role = args["_auth_role"]
    agent_id = args["_auth_agent_id"]

    with {:ok, mode} <- resolve_guidance_mode(args) do
      packet =
        cond do
          task_id && task_id != "" ->
            Acs.Memory.Guidance.for_task(task_id, tier: :full, mode: mode)

          scope_path && scope_path != "" ->
            Acs.Memory.Guidance.generate(scope_path,
              tier: :full,
              mode: mode,
              allowed_teams: allowed_teams,
              allowed_projects: allowed_projects,
              agent_role: agent_role,
              agent_id: agent_id
            )

          true ->
            Acs.Memory.Guidance.generate("",
              tier: :full,
              mode: mode,
              allowed_teams: allowed_teams,
              allowed_projects: allowed_projects,
              agent_role: agent_role,
              agent_id: agent_id
            )
        end

      {:ok, packet}
    end
  end

  # --- entity / intake / visibility ---

  defp normalize_about_args(args) do
    # Legacy aliases → about_*
    type =
      blank_to_nil(args["about_type"]) ||
        if about_person_fields?(args), do: "person", else: nil

    name =
      blank_to_nil(args["about_name"]) ||
        blank_to_nil(args["about_person_name"] || args["source_person_name"])

    email =
      blank_to_nil(args["about_email"]) ||
        blank_to_nil(args["about_person_email"] || args["source_person_email"])

    args
    |> Map.put("about_type", type)
    |> Map.put("about_name", name)
    |> Map.put("about_email", email)
  end

  defp about_person_fields?(args) do
    not is_nil(blank_to_nil(args["about_person_email"] || args["source_person_email"])) or
      not is_nil(blank_to_nil(args["about_person_name"] || args["source_person_name"]))
  end

  defp merge_intake_into_args(args, intake) do
    args
    |> Map.put("about_type", args["about_type"] || intake.about_type)
    |> Map.put("about_name", args["about_name"] || intake.about_name)
    |> Map.put("about_email", args["about_email"] || intake.about_email)
  end

  defp resolve_about_person_record(args, org) do
    if args["about_type"] == "person" or not is_nil(args["about_email"]) or
         not is_nil(args["about_name"]) do
      Acs.PersonStatus.get(org, email: args["about_email"], name: args["about_name"])
    else
      nil
    end
  end

  defp about_entity?(args) do
    not is_nil(args["about_type"]) or not is_nil(args["about_name"]) or
      not is_nil(args["about_email"])
  end

  defp explicit_visibility?(args) do
    truthy?(args["confidential"]) or
      (is_binary(args["visibility"]) and args["visibility"] != "")
  end

  # Blocking: not an eternal truth, or intake quality questions (except sensitive —
  # sensitive saves with a note). Skip when intake_confirmed.
  defp blocking_intake?(intake, args) do
    if truthy?(args["intake_confirmed"]) do
      false
    else
      not intake.is_eternal_truth or
        Enum.any?(intake.questions, fn q -> q["id"] not in ["sensitive", "scope"] end)
    end
  end

  defp scope_choice_payload(args, person, intake) do
    who =
      cond do
        match?(%Acs.PersonStatus{}, person) ->
          [person.name, person.status, person.rank && "rank:#{person.rank}"]
          |> Enum.reject(&(is_nil(&1) or &1 == ""))
          |> Enum.join(" · ")

        args["about_type"] == "company" and is_binary(args["about_name"]) ->
          "company #{args["about_name"]}"

        is_binary(args["about_name"]) ->
          args["about_name"]

        is_binary(args["about_email"]) ->
          args["about_email"]

        true ->
          args["about_type"] || "this entity"
      end

    %{
      status: "needs_scope_choice",
      saved: false,
      question:
        "This memory is about #{who}. At what level should it be scoped? Ask the user, then retry with visibility (or confidential: true for personal).",
      options: [
        %{visibility: "org", label: "Org — visible to everyone in the organization"},
        %{visibility: "team", label: "Team — only a specific team (also pass team:)"},
        %{visibility: "project", label: "Project — only a specific project (also pass project:)"},
        %{visibility: "personal", label: "Personal — only the saver can see it"}
      ],
      about: %{
        type: args["about_type"],
        name: args["about_name"],
        email: args["about_email"],
        person: person && Acs.PersonStatus.to_map(person)
      },
      intake: intake_summary(intake),
      retry_hint:
        "Retry save_memory with visibility: org|team|project|personal (team/project require team/project fields)."
    }
  end

  defp intake_questions_payload(args, intake) do
    %{
      status: "needs_input",
      saved: false,
      question:
        intake.notes ||
          "Intake needs clarification before saving. Ask the user, then retry with intake_confirmed: true (and any fixes).",
      questions: intake.questions,
      suggested_title: intake.suggested_title,
      suggested_kind: intake.suggested_kind,
      suggested_sensitive: intake.suggested_sensitive,
      suggested_visibility: intake.suggested_visibility,
      about: %{
        type: args["about_type"],
        name: args["about_name"],
        email: args["about_email"]
      },
      intake: intake_summary(intake),
      retry_hint: "Retry save_memory with answers applied and intake_confirmed: true."
    }
  end

  defp maybe_attach_sensitive_note(result, intake, visibility) do
    if intake.suggested_sensitive and visibility in [nil, "org"] do
      result
      |> Map.put(:suggested_sensitive, true)
      |> Map.put(
        :note,
        "Saved, but this looks sensitive. Ask the user if it should be personal (visibility: personal / confidential: true)."
      )
      |> Map.put(:suggested_visibility, intake.suggested_visibility || "personal")
      |> Map.put(:intake, intake_summary(intake))
    else
      Map.put(result, :intake, intake_summary(intake))
    end
  end

  defp intake_summary(intake) do
    %{
      source: intake.source,
      suggested_sensitive: intake.suggested_sensitive,
      suggested_visibility: intake.suggested_visibility,
      suggested_title: intake.suggested_title,
      suggested_kind: intake.suggested_kind,
      notes: intake.notes
    }
  end

  defp resolve_visibility_and_tags(args, person, tags) do
    confidential? = truthy?(args["confidential"])

    visibility =
      cond do
        confidential? -> "personal"
        is_binary(args["visibility"]) and args["visibility"] != "" -> args["visibility"]
        true -> "org"
      end

    tags =
      tags
      |> maybe_put_tag(args["about_type"], "about-type:")
      |> maybe_put_tag(args["about_name"], "about-name:")
      |> maybe_put_tag(args["about_email"], "about-email:")
      |> maybe_put_tag(person && person.email, "person-email:")
      |> maybe_put_tag(person && person.name, "person-name:")
      |> maybe_put_tag(person && person.status, "person-status:")
      |> maybe_put_tag(person && person.rank, "person-rank:")

    tags =
      if confidential? or visibility == "personal",
        do: maybe_put_tag(tags, "confidential", ""),
        else: tags

    {visibility, tags}
  end

  defp maybe_put_tag(tags, nil, _prefix), do: tags
  defp maybe_put_tag(tags, "", _prefix), do: tags

  defp maybe_put_tag(tags, value, "") when is_binary(value) do
    if value in tags, do: tags, else: [value | tags]
  end

  defp maybe_put_tag(tags, value, prefix) when is_binary(value) and is_binary(prefix) do
    tag = prefix <> value
    if tag in tags, do: tags, else: [tag | tags]
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("yes"), do: true
  defp truthy?(1), do: true
  defp truthy?(_), do: false

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil

  defp blank_to_nil(s) when is_binary(s) do
    t = String.trim(s)
    if t == "", do: nil, else: t
  end

  defp blank_to_nil(_), do: nil

  defp resolve_guidance_mode(args) do
    case parse_guidance_mode(args["mode"] || args["audience"]) do
      {:ok, mode} ->
        {:ok, mode}

      {:error, _} = err ->
        err

      :default ->
        audience = Acs.MCP.Audience.from_args(args)
        {:ok, Acs.MCP.Audience.to_guidance_mode(audience)}
    end
  end

  defp parse_guidance_mode(nil), do: :default
  defp parse_guidance_mode("mcp"), do: {:ok, :mcp}
  defp parse_guidance_mode("coding"), do: {:ok, :mcp}
  defp parse_guidance_mode("knowledge"), do: {:ok, :knowledge}
  defp parse_guidance_mode("chat"), do: {:ok, :knowledge}

  defp parse_guidance_mode(mode) when is_binary(mode),
    do: {:error, "Invalid mode '#{mode}'. Use mcp|coding or knowledge|chat"}

  # Layer 1: Check for exact duplicate by ID (same kind + same normalized title)
  defp check_exact_memory_duplicate(id) do
    case Acs.Memory.Indexer.get_memory(id, Acs.Org.current()) do
      nil ->
        :ok

      %{title: existing_title} ->
        {:error,
         "A memory with the same ID already exists: '#{existing_title}'. Use a different title or kind to avoid duplication."}
    end
  end

  # Layer 2 & 3: Check for semantic/lexical duplicates
  defp check_semantic_memory_duplicate(%Acs.Memory{} = memory) do
    retrieval_text = Acs.Memory.Embedding.memory_to_retrieval_text(memory)

    case Acs.Memory.Embedding.embed_text(retrieval_text) do
      {:ok, embedding} ->
        # Layer 2: Vector similarity search with high threshold
        current_storage_id = Acs.Memory.Indexer.storage_id(memory.org, memory.id)

        similar =
          Acs.Memory.VectorIndex.search_threshold(embedding, 0.92)
          |> Enum.filter(&tenant_embedding?(&1.memory_id, memory.org))

        # Exclude the memory itself (in case of re-save) and find strongest match
        case Enum.reject(similar, fn s -> s.memory_id == current_storage_id end) do
          [most_similar | _] ->
            public_id = Acs.Memory.Indexer.public_id(most_similar.memory_id, memory.org)
            other = Acs.Memory.Indexer.get_memory(public_id, memory.org)
            other_title = if other, do: other.title, else: public_id

            {:error,
             "A similar memory already exists (cosine similarity: #{Float.round(most_similar.similarity, 4)}): '#{other_title}'. Please review existing memories before creating a new one."}

          [] ->
            :ok
        end

      {:error, _reason} ->
        # Layer 3: Ollama unavailable — fall back to lexical comparison
        check_lexical_memory_duplicate(memory.title, memory.scope_path)
    end
  end

  # Layer 3 fallback: Check for memory with same title at the same scope
  defp check_lexical_memory_duplicate(title, scope_path) do
    title_lower = String.downcase(title)

    existing = Acs.Memory.Indexer.list_memories(scope_path: scope_path, org: Acs.Org.current())

    case Enum.find(existing, fn m ->
           m.scope_path == scope_path && String.downcase(m.title) == title_lower
         end) do
      nil ->
        :ok

      match ->
        {:error,
         "A memory with the title '#{match.title}' already exists at scope '#{scope_path}'. Duplicate titles at the same scope are not allowed."}
    end
  end

  defp tenant_embedding?(memory_id, org) do
    org = org || Acs.Org.current()

    if org == Acs.Org.configured() do
      not String.contains?(memory_id, ":")
    else
      String.starts_with?(memory_id, org <> ":")
    end
  end

  defp store_memory_embedding(%Acs.Memory{} = memory) do
    if memory.kind in Acs.Memory.embeddable_kinds() do
      retrieval_text = Acs.Memory.Embedding.memory_to_retrieval_text(memory)

      case Acs.Memory.Embedding.embed_text(retrieval_text) do
        {:ok, embedding} ->
          storage_id = Acs.Memory.Indexer.storage_id(memory.org, memory.id)
          Acs.Memory.VectorIndex.upsert_embedding(storage_id, embedding)

        {:error, reason} ->
          Logger.warning("[Tools] Could not store embedding for #{memory.id}: #{reason}")
      end
    else
      Logger.debug("[Tools] Skipping embedding for non-embeddable kind: #{memory.kind}")
    end

    :ok
  end

  defp decode_created_by(nil), do: nil

  defp decode_created_by(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  defp decode_created_by(_), do: nil

  defp do_save_with_validation(memory, memory_map) do
    with :ok <- check_exact_memory_duplicate(memory.id),
         :ok <- check_semantic_memory_duplicate(memory),
         {:ok, conflict_flags} <- Acs.Memory.Conflict.check_before_save(memory_map),
         :ok <- Acs.Memory.Loader.save(memory) do
      case Acs.Memory.Indexer.upsert_memory(memory) do
        {:ok, _} ->
          store_memory_embedding(memory)

          {:ok,
           %{
             id: memory.id,
             status: memory.status,
             conflict_flags: conflict_flags,
             message: "Memory saved with status: #{memory.status}"
           }}

        {:error, reason} ->
          Logger.error(
            "[Tools] Index upsert failed after save for #{memory.id}: #{inspect(reason)}"
          )

          {:error, "Memory saved but indexing failed: #{inspect(reason)}"}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end
end
