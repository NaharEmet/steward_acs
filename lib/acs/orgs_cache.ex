defmodule Acs.OrgsCache do
  @moduledoc false

  @table :orgs_cache
  @ttl_seconds 10

  def setup do
    :ets.new(@table, [:named_table, :public, read_concurrency: true, write_concurrency: true])
    :ok
  end

  def get do
    cutoff = cutoff()

    case :ets.lookup(@table, :orgs) do
      [{:orgs, orgs, ts}] when ts > cutoff -> orgs
      _ -> nil
    end
  end

  def put(orgs) do
    :ets.insert(@table, {:orgs, orgs, current_time()})
  end

  def invalidate do
    :ets.delete(@table, :orgs)
  end

  defp cutoff, do: current_time() - @ttl_seconds
  defp current_time, do: System.system_time(:second)
end
