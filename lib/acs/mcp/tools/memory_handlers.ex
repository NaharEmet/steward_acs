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
    visibility = args["visibility"] || "org"

    org = Acs.Org.current()

    memory_map = %{
      "id" => Acs.Memory.generate_id(%{"kind" => kind, "title" => title}),
      "kind" => kind,
      "title" => title,
      "summary" => summary,
      "content" => content,
      "scope_path" => scope_path,
      "importance" => importance,
      "tags" => tags,
      "triggers" => triggers,
      "failure_modes" => failure_modes,
      "created_by" => %{
        "type" => "developer",
        "id" => Acs.Cluster.developer_name(),
        "org" => org
      },
      "org" => org,
      "team" => team,
      "project" => project,
      "visibility" => visibility
    }

    memory_map =
      case Acs.Abac.memory_status_for_write(ctx, memory_map) do
        nil -> memory_map
        status -> Map.put(memory_map, "status", status)
      end

    with :ok <- Acs.Abac.validate_write(ctx, memory_map),
         :ok <- Acs.Memory.validate(memory_map) do
      memory = Acs.Memory.new(memory_map)
      do_save_with_validation(memory, memory_map)
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
      status: args["status"],
      limit: args["limit"] || 50,
      org: Acs.Org.current(),
      allowed_teams: args["_auth_allowed_teams"],
      allowed_projects: args["_auth_allowed_projects"],
      agent_role: args["_auth_role"]
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
            created_by: decode_created_by(m.created_by_json)
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
            created_by: decode_created_by(m.created_by_json)
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

    cond do
      status not in valid_statuses ->
        {:error, "Invalid status '#{status}'. Must be one of: #{Enum.join(valid_statuses, ", ")}"}

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

    with {:ok, mode} <- parse_guidance_mode(args["mode"]) do
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
              agent_role: agent_role
            )

          true ->
            %{
              scope: nil,
              scope_category: nil,
              tier: :full,
              mode: mode,
              critical_axioms: [],
              warnings: [],
              relevant_patterns: [],
              compressed_knowledge: "",
              maintenance_instructions: "",
              tool_reference: "",
              specs_instructions: "",
              specs_mismatch_protocol: "",
              workflow_basics: "",
              file_locking_protocol: "",
              memory_protocol: "",
              error_response_protocol: "",
              sleep_wake_protocol: "",
              agent_identity: "Find your agent_id: `get_present_status(agent_id: \"\")` returns your assigned name. Use it in all tool calls."
            }
        end

      {:ok, packet}
    end
  end

  defp parse_guidance_mode(nil), do: {:ok, :mcp}
  defp parse_guidance_mode("mcp"), do: {:ok, :mcp}
  defp parse_guidance_mode("knowledge"), do: {:ok, :knowledge}

  defp parse_guidance_mode(mode) when is_binary(mode),
    do: {:error, "Invalid mode '#{mode}'. Must be 'mcp' or 'knowledge'"}

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
        similar = Acs.Memory.VectorIndex.search_threshold(embedding, 0.92)

        # Exclude the memory itself (in case of re-save) and find strongest match
        case Enum.reject(similar, fn s -> s.memory_id == memory.id end) do
          [most_similar | _] ->
            other = Acs.Memory.Indexer.get_memory(most_similar.memory_id)
            other_title = if other, do: other.title, else: most_similar.memory_id

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

  defp store_memory_embedding(%Acs.Memory{} = memory) do
    if memory.kind in Acs.Memory.embeddable_kinds() do
      retrieval_text = Acs.Memory.Embedding.memory_to_retrieval_text(memory)

      case Acs.Memory.Embedding.embed_text(retrieval_text) do
        {:ok, embedding} ->
          Acs.Memory.VectorIndex.upsert_embedding(memory.id, embedding)

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
