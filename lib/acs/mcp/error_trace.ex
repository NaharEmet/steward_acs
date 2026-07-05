defmodule Acs.MCP.ErrorTrace do
  @moduledoc """
  Dedicated ETS-based storage for aggregated, deduplicated error traces.

  Unlike LogStore (ephemeral, 5-min TTL), this stores error patterns with a
  24-hour TTL, enabling long-lived tracking of recurring issues and automatic
  task creation for severe error patterns.

  ## Design

  - ETS `:set` table (not ordered_set) keyed by UUID string
  - Upsert semantics: same (service, component, message_pattern) within 1 hour
    increments the count; otherwise a fresh trace is created
  - 24-hour TTL based on `last_seen_at` to age out stale traces
  - Status lifecycle: `:new` → `:acknowledged` → `:resolved` or `:tasked` or `:failed`
  """

  use GenServer
  require Logger

  @table_name :acs_error_traces
  @ttl_seconds 86_400
  @dedup_window_seconds 3_600
  @trim_interval_seconds 300

  # ── Client API ──

  @doc """
  Starts the ErrorTrace GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Stores or updates an error trace. If a trace with the same
  (service, component, message_pattern) exists and was last seen less than
  1 hour ago, its count is incremented and `last_seen_at` updated.
  Otherwise a new trace is created.
  """
  def store_or_update_trace(service, component, message_pattern, sample_message, metadata \\ %{})

  def store_or_update_trace(_service, _component, nil, _sample_message, _metadata) do
    {:error, :nil_message_pattern}
  end

  def store_or_update_trace(service, component, message_pattern, sample_message, metadata) do
    if not table_exists?() do
      {:error, :no_table}
    else
      do_store_or_update(service, component, message_pattern, sample_message, metadata)
    end
  end

  @doc """
  Lists error traces with optional filters.

  ## Options

    * `:status` - Filter by status atom (`:new`, `:acknowledged`, `:resolved`, `:tasked`, `:failed`)
    * `:service` - Filter by service string
    * `:component` - Filter by component string
    * `:min_count` - Minimum count threshold
    * `:limit` - Max entries to return (default: 50)
  """
  def list_traces(opts \\ []) do
    status_filter = opts[:status]
    service_filter = opts[:service]
    component_filter = opts[:component]
    min_count = opts[:min_count]
    limit = opts[:limit] || 50

    if not table_exists?() do
      []
    else
      :acs_error_traces
      |> :ets.tab2list()
      |> Enum.map(fn {_id, entry} -> entry end)
      |> Enum.filter(&matches_status?(&1, status_filter))
      |> Enum.filter(&matches_service?(&1, service_filter))
      |> Enum.filter(&matches_component?(&1, component_filter))
      |> Enum.filter(&matches_min_count?(&1, min_count))
      |> Enum.sort_by(& &1.last_seen_at, {:desc, DateTime})
      |> Enum.take(limit)
    end
  end

  @doc """
  Gets a single error trace by its trace ID.
  """
  def get_trace(trace_id) when is_binary(trace_id) do
    if not table_exists?() do
      nil
    else
      case :ets.lookup(@table_name, trace_id) do
        [{^trace_id, entry}] -> entry
        [] -> nil
      end
    end
  end

  @doc """
  Sets a trace's status to `:acknowledged`.
  """
  def acknowledge_trace(trace_id) when is_binary(trace_id) do
    update_status(trace_id, :acknowledged)
  end

  @doc """
  Sets a trace's status to `:resolved`.
  """
  def resolve_trace(trace_id) when is_binary(trace_id) do
    update_status(trace_id, :resolved)
  end

  @doc """
  Sets a trace's status to `:tasked` and stores the associated task ID.
  """
  def mark_tasked(trace_id, task_id) do
    if not table_exists?() do
      {:error, :no_table}
    else
      case :ets.lookup(@table_name, trace_id) do
        [{^trace_id, entry}] ->
          updated = %{entry | status: :tasked, task_id: task_id}
          :ets.insert(@table_name, {trace_id, updated})
          {:ok, updated}

        [] ->
          {:error, :not_found}
      end
    end
  end

  @doc """
  Sets a trace's status to `:failed` with an error reason stored in metadata.
  """
  def mark_failed(trace_id, reason) when is_binary(trace_id) do
    if not table_exists?() do
      {:error, :no_table}
    else
      case :ets.lookup(@table_name, trace_id) do
        [{^trace_id, entry}] ->
          updated = %{
            entry
            | status: :failed,
              metadata: Map.put(entry.metadata, :failure_reason, reason)
          }

          :ets.insert(@table_name, {trace_id, updated})
          {:ok, updated}

        [] ->
          {:error, :not_found}
      end
    end
  end

  @doc """
  Deletes all traces older than 24 hours (based on `ttl_epoch`).
  Called periodically by the GenServer.
  """
  def trim_old_traces do
    if not table_exists?() do
      :ok
    else
      cutoff = DateTime.utc_now() |> DateTime.to_unix()

      trace_ids =
        :ets.select(
          @table_name,
          [{{:"$1", :"$2"}, [{:<, {:map_get, :ttl_epoch, :"$2"}, cutoff}], [:"$1"]}]
        )

      Enum.each(trace_ids, &:ets.delete(@table_name, &1))

      if trace_ids != [] do
        Logger.info("[ErrorTrace] Trimmed #{length(trace_ids)} expired traces")
      end

      :ok
    end
  end

  # ── GenServer Callbacks ──

  @impl true
  def init(_opts) do
    if :ets.info(@table_name, :name) != :undefined do
      :ets.delete(@table_name)
    end

    :ets.new(@table_name, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_trim()

    Logger.info("[ErrorTrace] Started ETS error trace storage")
    {:ok, %{count: 0}}
  end

  @impl true
  def handle_info(:trim_traces, state) do
    trim_old_traces()
    schedule_trim()
    {:noreply, state}
  end

  # ── Private Functions ──

  defp schedule_trim do
    Process.send_after(self(), :trim_traces, @trim_interval_seconds * 1_000)
  end

  defp table_exists? do
    :ets.info(@table_name, :name) != :undefined
  rescue
    e ->
      Logger.warning("[ErrorTrace] ETS table_exists? error: #{inspect(e)}")
      false
  end

  defp do_store_or_update(service, component, message_pattern, sample_message, metadata) do
    now = DateTime.utc_now()
    now_epoch = DateTime.to_unix(now)

    # Normalise message_pattern to first 100 chars
    norm_pattern = String.slice(message_pattern, 0, 100)

    # Look for an existing trace matching (service, component, pattern)
    match_result =
      :ets.select(@table_name, [
        {{:"$1", :"$2"},
         [
           {:andalso, {:==, {:map_get, :service, :"$2"}, service},
            {:andalso, {:==, {:map_get, :component, :"$2"}, component},
             {:==, {:map_get, :message_pattern, :"$2"}, norm_pattern}}}
         ], [:"$_"]}
      ])

    case match_result do
      [] ->
        # No existing trace — create new
        create_new_trace(
          service,
          component,
          norm_pattern,
          sample_message,
          metadata,
          now,
          now_epoch
        )

      matches when is_list(matches) ->
        # Take the most recently seen match (handle potential duplicates)
        {trace_id, entry} =
          matches
          |> Enum.max_by(fn {_id, e} -> e.last_seen_at end)

        # Clean up any duplicate entries for the same (service, component, pattern)
        duplicates = List.keydelete(matches, trace_id, 0)

        # Merge counts from duplicate entries to prevent data loss
        merged_count =
          Enum.reduce(duplicates, entry.count, fn {_id, e}, acc -> acc + e.count end)

        Enum.each(duplicates, fn {dup_id, _} ->
          :ets.delete(@table_name, dup_id)
        end)

        # Check if it's within the dedup window
        last_seen_epoch = DateTime.to_unix(entry.last_seen_at)
        age_seconds = now_epoch - last_seen_epoch

        if age_seconds < @dedup_window_seconds do
          # Within dedup window: increment count, update last_seen_at + ttl
          updated = %{
            entry
            | count: merged_count,
              last_seen_at: now,
              ttl_epoch: now_epoch + @ttl_seconds,
              sample_message: sample_message
          }

          :ets.insert(@table_name, {trace_id, updated})
          {:ok, :updated, updated}
        else
          # Outside dedup window: create new trace
          create_new_trace(
            service,
            component,
            norm_pattern,
            sample_message,
            metadata,
            now,
            now_epoch
          )
        end
    end
  end

  defp create_new_trace(
         service,
         component,
         message_pattern,
         sample_message,
         metadata,
         now,
         now_epoch
       ) do
    trace_id = Ecto.UUID.generate()

    entry = %{
      id: trace_id,
      timestamp: now,
      service: service,
      component: component,
      message_pattern: message_pattern,
      sample_message: sample_message,
      count: 1,
      status: :new,
      task_id: nil,
      level: :error,
      metadata: metadata,
      last_seen_at: now,
      ttl_epoch: now_epoch + @ttl_seconds
    }

    :ets.insert(@table_name, {trace_id, entry})
    {:ok, :created, entry}
  end

  defp update_status(trace_id, new_status) when new_status in [:acknowledged, :resolved] do
    if not table_exists?() do
      {:error, :no_table}
    else
      case :ets.lookup(@table_name, trace_id) do
        [{^trace_id, entry}] ->
          updated = %{entry | status: new_status}
          :ets.insert(@table_name, {trace_id, updated})
          {:ok, updated}

        [] ->
          {:error, :not_found}
      end
    end
  end

  # ── Post-filter helpers ──

  defp matches_status?(_entry, nil), do: true

  defp matches_status?(entry, filter) when is_atom(filter) do
    entry.status == filter
  end

  defp matches_status?(entry, filter) when is_binary(filter) do
    entry.status == String.to_existing_atom(filter)
  rescue
    ArgumentError -> false
  end

  defp matches_service?(_entry, nil), do: true
  defp matches_service?(entry, filter), do: entry.service == filter

  defp matches_component?(_entry, nil), do: true
  defp matches_component?(entry, filter), do: entry.component == filter

  defp matches_min_count?(_entry, nil), do: true
  defp matches_min_count?(entry, min) when is_integer(min), do: entry.count >= min
  defp matches_min_count?(_entry, _), do: true
end
