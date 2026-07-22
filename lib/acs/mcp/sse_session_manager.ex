defmodule Acs.MCP.SSESessionManager do
  @moduledoc """
  Registry for active MCP SSE sessions.

  Maps `session_id` to the `pid` of the process running the SSE receive loop.
  Other processes (e.g. the POST /mcp/messages handler) use this to dispatch
  JSON-RPC responses back to the correct SSE stream.
  """
  use GenServer

  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def register(session_id, pid, org \\ Acs.Org.current()) do
    GenServer.cast(__MODULE__, {:register, {org, session_id}, pid})
  end

  def unregister(session_id, org \\ Acs.Org.current()) do
    GenServer.cast(__MODULE__, {:unregister, {org, session_id}})
  end

  def alive?(session_id, org \\ Acs.Org.current()) do
    GenServer.call(__MODULE__, {:alive?, {org, session_id}})
  end

  def send_response(session_id, response, org \\ Acs.Org.current()) do
    GenServer.cast(__MODULE__, {:send_response, {org, session_id}, response})
  end

  def send_event(session_id, event, data, org \\ Acs.Org.current()) do
    GenServer.cast(__MODULE__, {:send_event, {org, session_id}, event, data})
  end

  @impl true
  def init(_) do
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:register, key, pid}, state) do
    state =
      case Map.pop(state, key) do
        {nil, state} ->
          state

        {{_pid, ref}, state} ->
          Process.demonitor(ref, [:flush])
          state
      end

    ref = Process.monitor(pid)
    Logger.debug("SSE session registered: #{inspect(key)}")
    {:noreply, Map.put(state, key, {pid, ref})}
  end

  @impl true
  def handle_cast({:unregister, key}, state) do
    Logger.debug("SSE session unregistered: #{inspect(key)}")

    state =
      case Map.pop(state, key) do
        {nil, state} ->
          state

        {{_pid, ref}, state} ->
          Process.demonitor(ref, [:flush])
          state
      end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:send_response, key, response}, state) do
    case Map.get(state, key) do
      nil ->
        Logger.warning("SSE session not found: #{inspect(key)}")
        :ok

      {pid, _ref} ->
        send(pid, {:send_response, response})
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:send_event, key, event, data}, state) do
    case Map.get(state, key) do
      nil -> :ok
      {pid, _ref} -> send(pid, {:send_event, event, data})
    end

    {:noreply, state}
  end

  @impl true
  def handle_call({:alive?, key}, _from, state) do
    {:reply, Map.has_key?(state, key), state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    state =
      case Enum.find(state, fn {_key, {session_pid, monitor_ref}} ->
             session_pid == pid and monitor_ref == ref
           end) do
        {key, _session} -> Map.delete(state, key)
        nil -> state
      end

    {:noreply, state}
  end
end
