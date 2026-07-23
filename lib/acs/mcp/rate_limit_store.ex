defmodule Acs.MCP.RateLimitStore do
  use GenServer

  require Logger

  @table :acs_rate_limit
  @cleanup_interval 60_000
  @max_entries 100_000

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def check(key, limit, window_ms) do
    now = System.system_time(:millisecond)
    bucket = div(now, window_ms)
    ets_key = {key, window_ms, bucket}
    expires_at = (bucket + 2) * window_ms

    case :ets.whereis(@table) do
      :undefined ->
        :deny

      _table ->
        try do
          if :ets.info(@table, :size) >= @max_entries and not :ets.member(@table, ets_key) do
            throw(:rate_limit_store_full)
          end

          count = :ets.update_counter(@table, ets_key, {2, 1}, {ets_key, 0, expires_at})
          if count > limit, do: :deny, else: :ok
        rescue
          ArgumentError -> :deny
        catch
          :rate_limit_store_full -> :deny
        end
    end
  end

  def cleanup(window_ms) do
    GenServer.call(__MODULE__, {:cleanup, window_ms})
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :set,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:cleanup, window_ms}, _from, state) do
    cleanup(window_ms, System.system_time(:millisecond))
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    deleted =
      :ets.select_delete(@table, [
        {{:"$1", :"$2", :"$3"}, [{:<, :"$3", System.system_time(:millisecond)}], [true]}
      ])

    if deleted > 0 do
      Logger.debug("[RateLimit] Cleaned up #{deleted} stale entries")
    end

    schedule_cleanup()
    {:noreply, state}
  end

  defp cleanup(window_ms, now) do
    stale_bucket_threshold = div(now, window_ms) - 1

    :ets.select_delete(@table, [
      {{{:"$1", window_ms, :"$2"}, :"$3", :"$4"}, [{:<, :"$2", stale_bucket_threshold}], [true]}
    ])
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
