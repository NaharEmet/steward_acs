defmodule Acs.MCP.HealthCache do
  @moduledoc false

  @table :tools_health_cache
  @ttl_seconds 30

  def setup do
    :ets.new(@table, [:named_table, :public, read_concurrency: true, write_concurrency: true])
    :ok
  end

  def get_all do
    cutoff = cutoff()
    :ets.foldl(fn
      {app, status, ts}, acc when ts > cutoff -> Map.put(acc, app, status)
      _, acc -> acc
    end, %{}, @table)
  end

  def put_all(results) when is_map(results) do
    now = current_time()
    entries = Enum.map(results, fn {app, status} -> {app, status, now} end)
    :ets.insert(@table, entries)
  end

  defp cutoff, do: current_time() - @ttl_seconds
  defp current_time, do: System.system_time(:second)
end
