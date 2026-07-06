defmodule Acs.Log.LogRepo do
  @moduledoc """
  DB-backed log storage and query context.

  Provides insert, query, and retention operations for log entries.
  Metadata is stored as a map in the schema and serialized as JSON
  text in the database by Ecto's `:map` type.

  ## Dual-Write Architecture

  Logs are dual-written to ETS (fast recent queries via `Acs.MCP.LogStore`)
  and to this repository (persistent storage across restarts). This module
  handles only the persistent DB path.
  """
  require Logger

  alias Acs.Log.LogEntry
  alias Acs.Repo

  import Ecto.Query

  @doc """
  Insert a `%LogEntry{}` struct into the database.
  """
  def insert(%LogEntry{} = entry) do
    Repo.insert(entry)
  end

  @doc """
  Insert a log entry from raw fields.

  Called by `Acs.MCP.LogStore` for async DB persistence.
  Metadata is a map (Ecto handles JSON serialization).
  """
  def insert_raw(level, service, component, message, metadata_map \\ %{}, opts \\ []) do
    now_usec = DateTime.utc_now()
    now = DateTime.truncate(now_usec, :second)

    attrs = %{
      id: Ecto.UUID.generate(),
      timestamp: now_usec,
      level: level,
      service: service,
      component: component,
      message: message,
      metadata: metadata_map,
      workflow_id: Keyword.get(opts, :workflow_id),
      execution_id: Keyword.get(opts, :execution_id),
      org: Keyword.get(opts, :org, Acs.Org.current()),
      inserted_at: now,
      updated_at: now
    }

    %LogEntry{}
    |> LogEntry.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Query log entries with filters.

  Returns list of `%LogEntry{}` structs with decoded metadata maps.

  ## Filters

    * `level` - Atom or list of level strings to match (e.g. `:error`, `["error", "warning"]`)
    * `component` - Substring match on component field
    * `search` - Substring match on message (LIKE %search%)
    * `org` - Exact match on org field
    * `workflow_id` - Exact match
    * `execution_id` - Exact match
    * `since` - `%DateTime{}` or ISO8601 string (timestamp >= since)
    * `until` - `%DateTime{}` or ISO8601 string (timestamp <= until)
    * `limit` - Max results (default: 100)
    * `offset` - Pagination offset (default: 0)
    * `order` - `:newest` (default, timestamp DESC) or `:oldest` (timestamp ASC)
  """
  def query(filters \\ []) do
    base = from(e in LogEntry)

    base = apply_level_filter(base, filters[:level])
    base = apply_component_filter(base, filters[:component])
    base = apply_search_filter(base, filters[:search])
    base = apply_org_filter(base, filters[:org])
    base = apply_field_filter(base, :workflow_id, filters[:workflow_id])
    base = apply_field_filter(base, :execution_id, filters[:execution_id])
    base = apply_since_filter(base, filters[:since])
    base = apply_until_filter(base, filters[:until])

    ordered =
      case filters[:order] do
        :oldest -> from(e in base, order_by: [asc: e.timestamp])
        _ -> from(e in base, order_by: [desc: e.timestamp])
      end

    limit = filters[:limit] || 100
    offset = filters[:offset] || 0

    from(e in ordered, limit: ^limit, offset: ^offset)
    |> Repo.all()
  end

  @doc """
  Count log entries matching optional level/cluster filters.

  Returns integer count.
  """
  def count(filters \\ []) do
    base = from(e in LogEntry)

    base = apply_level_filter(base, filters[:level])
    base = apply_org_filter(base, filters[:org])

    Repo.aggregate(base, :count, :id)
  end

  @doc """
  Delete old log entries based on retention policy.

  - Non-error logs: deleted if timestamp < `older_than` (default: 24 hours ago)
  - Error logs: deleted if timestamp < `error_older_than` (default: 30 days ago)

  Returns `{normal_deleted, error_deleted}`.
  """
  def delete_old(opts \\ []) do
    older_than = Keyword.get(opts, :older_than, hours_ago(24))
    error_older_than = Keyword.get(opts, :error_older_than, days_ago(30))

    {normal_count, _} =
      from(e in LogEntry, where: e.level != "error" and e.timestamp < ^older_than)
      |> Repo.delete_all()

    {error_count, _} =
      from(e in LogEntry, where: e.level == "error" and e.timestamp < ^error_older_than)
      |> Repo.delete_all()

    {normal_count, error_count}
  end

  # -- Filter helpers --

  defp apply_level_filter(query, nil), do: query

  defp apply_level_filter(query, level) do
    levels = if is_list(level), do: Enum.map(level, &to_string/1), else: [to_string(level)]
    from(e in query, where: e.level in ^levels)
  end

  defp apply_component_filter(query, nil), do: query

  defp apply_component_filter(query, component) do
    from(e in query, where: like(e.component, ^"%#{component}%"))
  end

  defp apply_search_filter(query, nil), do: query

  defp apply_search_filter(query, search) do
    from(e in query, where: like(e.message, ^"%#{search}%"))
  end

  defp apply_org_filter(query, nil), do: query

  defp apply_org_filter(query, org) do
    from(e in query, where: e.org == ^org)
  end

  defp apply_field_filter(query, _field, nil), do: query

  defp apply_field_filter(query, field, value) do
    from(e in query, where: field(e, ^field) == ^value)
  end

  defp apply_since_filter(query, nil), do: query

  defp apply_since_filter(query, since) do
    since_dt = parse_datetime(since)
    from(e in query, where: e.timestamp >= ^since_dt)
  end

  defp apply_until_filter(query, nil), do: query

  defp apply_until_filter(query, until) do
    until_dt = parse_datetime(until)
    from(e in query, where: e.timestamp <= ^until_dt)
  end

  defp parse_datetime(%DateTime{} = dt), do: dt

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ ->
        Logger.warning("[LogRepo] Invalid datetime: #{str}")
        raise ArgumentError, "Invalid datetime: #{str}"
    end
  end

  defp hours_ago(n), do: DateTime.add(DateTime.utc_now(), -n * 3600, :second)
  defp days_ago(n), do: DateTime.add(DateTime.utc_now(), -n * 86_400, :second)
end
