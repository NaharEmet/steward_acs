defmodule Acs.MCP.HealthCheckCache do
  @moduledoc """
  Short-lived cache for dashboard app health checks.

  Health probes are advisory UI data. Keeping them in memory avoids repeating
  slow outbound requests every time a LiveView is mounted.
  """

  use GenServer

  @table __MODULE__
  @default_ttl_ms 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get(url) when is_binary(url) do
    case :ets.lookup(@table, url) do
      [{^url, status, checked_at}] ->
        if System.monotonic_time(:millisecond) - checked_at < ttl_ms(),
          do: {:ok, status},
          else: :miss

      [] ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  def put(url, status) when is_binary(url) and status in [:up, :down] do
    true = :ets.insert(@table, {url, status, System.monotonic_time(:millisecond)})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def clear do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
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

    {:ok, %{}}
  end

  defp ttl_ms do
    Application.get_env(:steward_acs, __MODULE__, [])
    |> Keyword.get(:ttl_ms, @default_ttl_ms)
  end
end
