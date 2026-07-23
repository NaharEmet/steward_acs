defmodule Acs.MCP.BridgeSessionStore do
  @moduledoc false

  use GenServer

  @session_ttl_ms 300_000
  @cleanup_interval_ms 60_000
  @max_sessions 10_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def put(session_id, session) when is_binary(session_id) and is_map(session) do
    GenServer.call(__MODULE__, {:put, session_id, session})
  end

  def fetch(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:fetch, session_id})
  end

  @impl true
  def init(state) do
    schedule_cleanup()
    {:ok, state}
  end

  @impl true
  def handle_call({:put, session_id, session}, _from, state) do
    state = if map_size(state) >= @max_sessions, do: remove_expired(state), else: state

    if map_size(state) >= @max_sessions and not Map.has_key?(state, session_id) do
      {:reply, {:error, :session_limit_reached}, state}
    else
      stored = Map.put(session, :inserted_at, System.monotonic_time(:millisecond))
      {:reply, :ok, Map.put(state, session_id, stored)}
    end
  end

  def handle_call({:fetch, session_id}, _from, state) do
    case Map.fetch(state, session_id) do
      {:ok, session} ->
        if expired?(session) do
          {:reply, {:error, :expired}, Map.delete(state, session_id)}
        else
          {:reply, {:ok, session}, state}
        end

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_info(:cleanup, state) do
    schedule_cleanup()
    {:noreply, remove_expired(state)}
  end

  defp remove_expired(state) do
    Map.reject(state, fn {_session_id, session} -> expired?(session) end)
  end

  defp expired?(session) do
    System.monotonic_time(:millisecond) - session.inserted_at > @session_ttl_ms
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
