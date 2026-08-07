defmodule Acs.MCP.OAuth.BrokerStore do
  @moduledoc """
  In-memory session store for the ACS OAuth broker.

  Maps an opaque broker state to the client's original redirect URI, state,
  and the PKCE verifier the broker generated. Also indexes Auth0 codes back
  to their session so the `/token` endpoint can exchange the code server-side.

  Sessions expire after `@ttl_seconds` and are swept periodically.
  """

  use GenServer

  @table :acs_oauth_broker_sessions
  @code_table :acs_oauth_broker_codes
  @ttl_seconds 600
  @sweep_interval_ms 60_000

  @type session :: %{
          required(:client_redirect_uri) => String.t(),
          required(:client_state) => String.t(),
          required(:code_verifier) => String.t(),
          required(:expires_at) => pos_integer()
        }

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @spec put(String.t(), map()) :: :ok
  def put(state, session) do
    GenServer.call(__MODULE__, {:put, state, session})
  end

  @spec get(String.t()) :: session() | nil
  def get(state) do
    GenServer.call(__MODULE__, {:get, state})
  end

  @spec put_code(String.t(), String.t()) :: :ok
  def put_code(code, state) do
    GenServer.call(__MODULE__, {:put_code, code, state})
  end

  @spec get_by_code(String.t()) :: session() | nil
  def get_by_code(code) do
    GenServer.call(__MODULE__, {:get_by_code, code})
  end

  @doc "Drop all sessions/codes (tests only)."
  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @impl GenServer
  def init(:ok) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@code_table, [:named_table, :set, :public, read_concurrency: true])
    Process.send_after(self(), :sweep, @sweep_interval_ms)
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:put, state, session}, _from, server_state) do
    expires_at = System.system_time(:second) + @ttl_seconds
    :ets.insert(@table, {state, Map.put(session, :expires_at, expires_at)})
    {:reply, :ok, server_state}
  end

  def handle_call({:get, state}, _from, server_state) do
    {:reply, lookup(@table, state), server_state}
  end

  def handle_call({:put_code, code, state}, _from, server_state) do
    :ets.insert(@code_table, {code, state})
    {:reply, :ok, server_state}
  end

  def handle_call({:get_by_code, code}, _from, server_state) do
    session =
      case lookup(@code_table, code) do
        nil -> nil
        state -> lookup(@table, state)
      end

    {:reply, session, server_state}
  end

  @impl GenServer
  def handle_call(:clear, _from, server_state) do
    :ets.delete_all_objects(@table)
    :ets.delete_all_objects(@code_table)
    {:reply, :ok, server_state}
  end

  @impl GenServer
  def handle_info(:sweep, server_state) do
    now = System.system_time(:second)

    expired_states =
      @table
      |> :ets.tab2list()
      |> Enum.reduce([], fn {state, session}, acc ->
        if Map.get(session, :expires_at, 0) < now, do: [state | acc], else: acc
      end)

    Enum.each(expired_states, &:ets.delete(@table, &1))

    @code_table
    |> :ets.tab2list()
    |> Enum.each(fn {code, state} ->
      if :ets.lookup(@table, state) == [] do
        :ets.delete(@code_table, code)
      end
    end)

    Process.send_after(self(), :sweep, @sweep_interval_ms)
    {:noreply, server_state}
  end

  defp lookup(table, key) do
    case :ets.lookup(table, key) do
      [{^key, value}] -> value
      [] -> nil
    end
  end
end
