defmodule Acs.MCP.ClientSession do
  @moduledoc """
  Per-MCP-session metadata (audience, clientInfo) captured at `initialize`.

  Keys may be:
  - binary session_id (HTTP/SSE)
  - `{:agent, agent_identity}` fallback when session ids are not sticky

  Request-scoped session id is bound via `bind/2` so Protocol can read it
  without changing every call site arity.
  """

  use GenServer

  @process_key {__MODULE__, :session_id}
  @session_ttl_ms 3_600_000
  @cleanup_interval_ms 60_000
  @max_sessions 10_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "Bind session_id for the duration of fun/0 (request-scoped)."
  def bind(session_id, fun) when is_function(fun, 0) do
    previous = Process.get(@process_key)
    Process.put(@process_key, session_id)

    try do
      fun.()
    after
      if previous, do: Process.put(@process_key, previous), else: Process.delete(@process_key)
    end
  end

  def current_id, do: Process.get(@process_key)

  def put(nil, _attrs), do: :ok

  def put(key, attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:put, key, attrs})
  end

  def fetch(nil), do: {:error, :not_found}

  def fetch(key) do
    GenServer.call(__MODULE__, {:fetch, key})
  end

  @doc """
  Resolve audience for the current request.

  Prefers the bound session id, then `{:agent, agent_identity}`, else default.
  """
  def resolve_audience(agent_identity \\ nil) do
    with {:error, _} <- fetch_audience(current_id()),
         {:error, _} <- fetch_audience(agent_key(agent_identity)) do
      Acs.MCP.Audience.default_audience()
    else
      {:ok, audience} -> audience
    end
  end

  def remember_initialize(params, agent_identity) when is_map(params) do
    audience = Acs.MCP.Audience.from_initialize_params(params)
    client_info = params["clientInfo"] || params[:clientInfo] || %{}

    attrs = %{
      audience: audience,
      client_name: client_info["name"] || client_info[:name],
      client_version: client_info["version"] || client_info[:version]
    }

    put(current_id(), attrs)
    put(agent_key(agent_identity), attrs)
    audience
  end

  defp fetch_audience(nil), do: {:error, :not_found}

  defp fetch_audience(key) do
    case fetch(key) do
      {:ok, %{audience: audience}} when audience in [:coding, :chat] -> {:ok, audience}
      _ -> {:error, :not_found}
    end
  end

  defp agent_key(nil), do: nil
  defp agent_key(""), do: nil
  defp agent_key(id) when is_binary(id), do: {:agent, id}
  defp agent_key(_), do: nil

  @impl true
  def init(state) do
    schedule_cleanup()
    {:ok, state}
  end

  @impl true
  def handle_call({:put, key, attrs}, _from, state) do
    state = if map_size(state) >= @max_sessions, do: remove_expired(state), else: state

    if map_size(state) >= @max_sessions and not Map.has_key?(state, key) do
      {:reply, {:error, :session_limit_reached}, state}
    else
      stored = Map.merge(attrs, %{inserted_at: System.monotonic_time(:millisecond)})
      {:reply, :ok, Map.put(state, key, stored)}
    end
  end

  def handle_call({:fetch, key}, _from, state) do
    case Map.fetch(state, key) do
      {:ok, session} ->
        if expired?(session) do
          {:reply, {:error, :expired}, Map.delete(state, key)}
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
    Map.reject(state, fn {_key, session} -> expired?(session) end)
  end

  defp expired?(session) do
    System.monotonic_time(:millisecond) - session.inserted_at > @session_ttl_ms
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
