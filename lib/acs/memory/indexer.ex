defmodule Acs.Memory.Indexer do
  @moduledoc """
  Synchronizes YAML memory files into the SQLite index.

  The YAML files are canonical. The indexer reads all YAML files
  and upserts their contents into the acs_memories SQLite table
  for fast querying and FTS5 search.
  """

  alias Acs.Memory.Retry
  alias Acs.Repo
  alias Acs.Memory.Schema

  require Logger

  @doc """
  Syncs all YAML memory files into the SQLite index.
  Returns {:ok, count, quarantined} where count is number of synced
  memories and quarantined is list of error tuples.
  """
  def sync_all do
    # First, quarantine any invalid files (writes parse_error status to
    # valid-YAML-but-invalid-validation files so they can be tracked)
    Acs.Memory.Loader.quarantine_invalid()

    {:ok, memories, quarantined} = Acs.Memory.Loader.load_all()

    count = Enum.reduce(memories, 0, fn memory, acc ->
      case upsert_memory(memory) do
        {:ok, _} -> acc + 1
        {:error, reason} ->
          Logger.warning("[Memory.Indexer] Failed to index #{memory.id}: #{reason}")
          acc
      end
    end)

    Logger.info("[Memory.Indexer] Synced #{count} memories, #{length(quarantined)} quarantined")
    {:ok, count, quarantined}
  end

  @doc """
  Upserts a single Acs.Memory into the SQLite index.
  Uses Repo.insert with on_conflict: :replace_all.
  """
  def upsert_memory(%Acs.Memory{} = memory) do
    attrs = %{
      id: memory.id,
      kind: memory.kind,
      status: memory.status,
      title: memory.title,
      summary: memory.summary,
      content: memory.content,
      scope_path: memory.scope_path,
      importance: memory.importance,
      tags_json: Jason.encode!(memory.tags || []),
      triggers_json: Jason.encode!(memory.triggers || []),
      failure_modes_json: Jason.encode!(memory.failure_modes || []),
      related_memories_json: Jason.encode!(memory.related_memories || []),
      verification_json: Jason.encode!(memory.verification),
      revalidation_json: Jason.encode!(memory.revalidation),
      created_by_json: Jason.encode!(memory.created_by),
      created_by_agent: get_in(memory.created_by, ["id"]),
      file_path: Acs.Memory.Loader.memory_to_path(memory),
      created_at: parse_datetime(memory.created_at),
      updated_at: parse_datetime(memory.updated_at)
    }

    result =
      Retry.with_busy_retry(fn ->
        %Schema{}
        |> Schema.changeset(attrs)
        |> Repo.insert(on_conflict: :replace_all, conflict_target: :id)
      end)

    case result do
      {:ok, _} -> {:ok, memory}
      {:error, changeset} -> {:error, inspect(changeset.errors)}
    end
  end

  @doc """
  Removes a memory from the index by id.
  """
  def remove_memory(memory_id) do
    Retry.with_busy_retry(fn ->
      case Repo.get(Schema, memory_id) do
        nil -> :ok
        schema -> Repo.delete(schema)
      end
    end)
  end

  @doc """
  Updates the status of a memory in the index.
  """
  def update_status(memory_id, new_status) when new_status in ~w(proposed approved rejected stale deprecated archived parse_error) do
    Retry.with_busy_retry(fn ->
      case Repo.get(Schema, memory_id) do
        nil -> {:error, "Memory not found: #{memory_id}"}
        schema ->
          schema
          |> Ecto.Changeset.change(%{status: new_status, updated_at: DateTime.utc_now() |> DateTime.truncate(:second)})
          |> Repo.update()
      end
    end)
  end

  @doc """
  Updates a specific field on a memory in the index.
  Returns {:ok, schema} or {:error, reason}.
  """
  def update_field(memory_id, field, value) when field in ~w(title content)a do
    Retry.with_busy_retry(fn ->
      case Repo.get(Schema, memory_id) do
        nil -> {:error, "Memory not found: #{memory_id}"}
        schema ->
          schema
          |> Ecto.Changeset.change(%{field => value, updated_at: DateTime.utc_now() |> DateTime.truncate(:second)})
          |> Repo.update()
      end
    end)
  end

  @doc """
  Gets a memory from the index by id.
  """
  def get_memory(memory_id) do
    Repo.get(Schema, memory_id)
  end

  @doc """
  Fetches memories by a list of IDs and returns a map of %{id => schema}.
  """
  def get_memories_by_ids(ids) when is_list(ids) do
    import Ecto.Query

    Repo.all(from m in Schema, where: m.id in ^ids)
    |> Enum.into(%{}, fn m -> {m.id, m} end)
  end

  @doc """
  Returns a map of status -> count for all memories in the index.
  Uses a single query with GROUP BY instead of N individual queries.
  """
  def count_by_status do
    import Ecto.Query

    query = from m in Schema,
      group_by: m.status,
      select: %{status: m.status, count: count(m.id)}

    Repo.all(query)
    |> Enum.into(%{}, fn %{status: s, count: c} -> {s, c} end)
  end

  @doc """
  Lists memories from the index with optional filters.
  """
  def list_memories(opts \\ []) do
    import Ecto.Query

    order_by = opts[:order_by] || [desc: :updated_at]
    query = from m in Schema, order_by: ^order_by

    query = if opts[:kind], do: from(m in query, where: m.kind == ^opts[:kind]), else: query
    query =
      if opts[:status] do
        if is_list(opts[:status]) do
          from(m in query, where: m.status in ^opts[:status])
        else
          from(m in query, where: m.status == ^opts[:status])
        end
      else
        query
      end
    query = if opts[:scope_path] do
      from m in query, where: like(m.scope_path, ^"#{opts[:scope_path]}%")
    else
      query
    end
    query = if opts[:limit], do: from(m in query, limit: ^opts[:limit]), else: query

    Repo.all(query)
  end

  @doc """
  Lists memories that have audit error count > 0 (need human review).
  Fetches proposed memories and filters those with error counts in auditor_flags.
  """
  def list_memories_needing_review(opts \\ []) do
    limit = opts[:limit] || 100

    # Fetch proposed memories (the ones the auditor processes)
    proposed = list_memories(status: "proposed", limit: limit * 2)

    # Filter to only those with audit error flags
    proposed
    |> Enum.filter(fn m ->
      case m.auditor_flags do
        nil -> false
        json when is_binary(json) ->
          case Jason.decode(json) do
            {:ok, flags} ->
              Map.get(flags, "audit_error_count", 0) > 0
            _ -> false
          end
        _ -> false
      end
    end)
    |> Enum.take(limit)
  end

  @doc """
  Count memories needing review (have audit error count > 0).
  """
  def count_memories_needing_review do
    proposed = list_memories(status: "proposed", limit: 500)

    proposed
    |> Enum.count(fn m ->
      case m.auditor_flags do
        nil -> false
        json when is_binary(json) ->
          case Jason.decode(json) do
            {:ok, flags} ->
              Map.get(flags, "audit_error_count", 0) > 0
            _ -> false
          end
        _ -> false
      end
    end)
  end

  @doc """
  Searches memories using LIKE-based text search.
  Returns a list of matching Schema records.
  """
  def search(query_text, opts \\ []) do
    import Ecto.Query

    search_term = "%#{query_text}%"

    search_query = from m in Schema,
      where: like(m.title, ^search_term) or
             like(m.content, ^search_term) or
             like(m.summary, ^search_term),
      order_by: [desc: m.importance, desc: m.updated_at]

    search_query = if opts[:scope_path] do
      from m in search_query, where: like(m.scope_path, ^"#{opts[:scope_path]}%")
    else
      search_query
    end

    search_query = if opts[:kind] do
      from m in search_query, where: m.kind == ^opts[:kind]
    else
      search_query
    end

    search_query =
      if opts[:status] do
        if is_list(opts[:status]) do
          from(m in search_query, where: m.status in ^opts[:status])
        else
          from(m in search_query, where: m.status == ^opts[:status])
        end
      else
        search_query
      end

    search_query = if opts[:limit] do
      from m in search_query, limit: ^opts[:limit]
    else
      from m in search_query, limit: 50
    end

    Repo.all(search_query)
  end

  @doc """
  Converts an Acs.Memory.Schema Ecto struct to a string-keyed attrs map
  suitable for Acs.Memory.new/1. Handles JSON field decoding and type conversions.
  """
  def schema_to_memory_attrs(%Acs.Memory.Schema{} = schema) do
    %{
      "id" => schema.id,
      "kind" => schema.kind,
      "status" => schema.status,
      "title" => schema.title,
      "summary" => schema.summary,
      "content" => schema.content,
      "scope_path" => schema.scope_path,
      "importance" => schema.importance,
      "tags" => decode_json_field(schema.tags_json),
      "triggers" => decode_json_field(schema.triggers_json),
      "failure_modes" => decode_json_field(schema.failure_modes_json),
      "related_memories" => decode_json_field(schema.related_memories_json),
      "verification" => decode_json_field(schema.verification_json),
      "revalidation" => decode_json_field(schema.revalidation_json),
      "created_by" => decode_json_field(schema.created_by_json),
      "created_at" => format_datetime(schema.created_at),
      "updated_at" => format_datetime(schema.updated_at)
    }
  end

  defp decode_json_field(nil), do: nil
  defp decode_json_field(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, value} -> value
      _ -> nil
    end
  end
  defp decode_json_field(_), do: nil

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: dt |> DateTime.to_iso8601()
  defp format_datetime(%NaiveDateTime{} = ndt), do: ndt |> NaiveDateTime.to_iso8601()

  defp parse_datetime(nil), do: DateTime.utc_now()
  defp parse_datetime(dt) when is_struct(dt, DateTime), do: dt
  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

end
