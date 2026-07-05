defmodule Acs.Acs.SleepRegistry do
  @moduledoc """
  In-memory registry for sleeping agents.

  Manages a FIFO queue of sleeping agents and dispatches newly created tasks
  to the next waiting agent. Agents register with a unique reference (`make_ref()`)
  to avoid race conditions between timeouts and dispatches.

  ## State
  - `sleepers`: `%{agent_id => %{agent_id, pid, ref, timeout, registered_at}}`
  - `queue`: `:queue` of agent_ids (FIFO)
  - `dispatched`: `%{agent_id => task_id}` — agents that were woken with a task
  """

  use GenServer, restart: :permanent

  require Logger

  @name __MODULE__

  # ──────────────────────────── Public API ────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc """
  Registers an agent for sleep.

  Returns `{:ok, ref, :enqueued}` if agent is now sleeping (no pending tasks).
  Returns `{:ok, ref, :immediate, task_id}` if a pending task was found and dispatched.
  Returns `{:error, :already_sleeping}` if agent is already registered.
  Returns `{:error, :has_active_task}` if agent has an active task in ACS.
  """
  def register(agent_id, timeout \\ :infinity) do
    GenServer.call(@name, {:register, agent_id, timeout}, :infinity)
  end

  @doc """
  Unregisters a sleeping agent. Returns `:ok`.
  """
  def unregister(agent_id) do
    GenServer.call(@name, {:unregister, agent_id})
  end

  @doc """
  Pops the next waiting agent from the queue and dispatches the given task.

  Returns `{:ok, agent_id, task_id}` on successful dispatch.
  Returns `{:error, :no_sleeping_agents}` if queue is empty.
  """
  def try_dispatch(task_id) do
    GenServer.call(@name, {:try_dispatch, task_id})
  end

  @doc """
  Manually wakes a sleeping agent via cancellation.
  Returns `{:ok, :cancelled}` or `{:error, :not_sleeping}`.
  """
  def wake_agent(agent_id) do
    GenServer.call(@name, {:wake_agent, agent_id})
  end

  @doc """
  Returns list of currently sleeping agents.
  Each entry: `%{agent_id: string, registered_at: DateTime, timeout: integer | :infinity}`
  """
  def list_sleeping_agents do
    GenServer.call(@name, :list_sleeping_agents)
  end

  # ──────────────────────────── GenServer Callbacks ────────────────────────────

  @impl true
  def init(_opts) do
    Logger.info("[SleepRegistry] Starting...")
    {:ok, %{sleepers: %{}, queue: :queue.new(), dispatched: %{}}}
  end

  @impl true
  def handle_call({:register, agent_id, timeout}, {pid, _tag} = _from, state) do
    # Clean any stale dispatched entry from a prior dispatch cycle
    state = %{state | dispatched: Map.delete(state.dispatched, agent_id)}

    if Map.has_key?(state.sleepers, agent_id) do
      {:reply, {:error, :already_sleeping}, state}
    else
      ref = make_ref()
      Process.monitor(pid)

      # Check for pending unassigned todo tasks
      pending_task =
        try do
          find_pending_task()
        rescue
          e ->
            Logger.error("[SleepRegistry] Failed to find pending task: #{inspect(e)}")
            nil
        end

      case pending_task do
        nil ->
          sleeper = %{
            agent_id: agent_id,
            pid: pid,
            ref: ref,
            timeout: timeout,
            registered_at: now()
          }

          sleepers = Map.put(state.sleepers, agent_id, sleeper)
          queue = :queue.in(agent_id, state.queue)

          Logger.info(
            "[SleepRegistry] Agent #{agent_id} sleeping (queue depth: #{:queue.len(queue)})"
          )

          {:reply, {:ok, ref, :enqueued}, %{state | sleepers: sleepers, queue: queue}}

        task ->
          send(pid, {:task_assigned, ref, task.id})
          dispatched = Map.put(state.dispatched, agent_id, task.id)
          Logger.info("[SleepRegistry] Agent #{agent_id} dispatched pending task #{task.id}")
          {:reply, {:ok, ref, :immediate, task.id}, %{state | dispatched: dispatched}}
      end
    end
  end

  @impl true
  def handle_call({:unregister, agent_id}, _from, state) do
    {:reply, :ok, do_unregister(state, agent_id)}
  end

  @impl true
  def handle_call({:try_dispatch, task_id}, _from, state) do
    case pop_valid(state) do
      {:error, :empty, state} ->
        {:reply, {:error, :no_sleeping_agents}, state}

      {:error, :queue_reset, state} ->
        {:reply, {:error, :no_sleeping_agents}, state}

      {:ok, agent_id, state} ->
        sleeper = Map.fetch!(state.sleepers, agent_id)
        send(sleeper.pid, {:task_assigned, sleeper.ref, task_id})
        dispatched = Map.put(state.dispatched, agent_id, task_id)
        state = do_unregister(state, agent_id)
        Logger.info("[SleepRegistry] Dispatched task #{task_id} to agent #{agent_id}")
        {:reply, {:ok, agent_id, task_id}, %{state | dispatched: dispatched}}
    end
  end

  @impl true
  def handle_call({:wake_agent, agent_id}, _from, state) do
    case Map.fetch(state.sleepers, agent_id) do
      {:ok, sleeper} ->
        send(sleeper.pid, {:cancelled, sleeper.ref})
        state = do_unregister(state, agent_id)
        Logger.info("[SleepRegistry] Manual wake of agent #{agent_id}")
        {:reply, {:ok, :cancelled}, state}

      :error ->
        {:reply, {:error, :not_sleeping}, state}
    end
  end

  @impl true
  def handle_call(:list_sleeping_agents, _from, state) do
    agents =
      Enum.map(state.sleepers, fn {_id, sleeper} ->
        %{
          agent_id: sleeper.agent_id,
          registered_at: sleeper.registered_at,
          timeout: sleeper.timeout
        }
      end)

    {:reply, agents, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    agent_id =
      Enum.find_value(state.sleepers, fn {id, sleeper} ->
        if sleeper.pid == pid, do: id, else: nil
      end)

    case agent_id do
      nil ->
        {:noreply, state}

      id ->
        Logger.info("[SleepRegistry] Agent #{id} process exited: #{inspect(reason)}")
        {:noreply, do_unregister(state, id)}
    end
  end

  # ──────────────────────────── Private ────────────────────────────

  defp do_unregister(state, agent_id) do
    state
    |> Map.update!(:sleepers, &Map.delete(&1, agent_id))
    |> Map.update!(:dispatched, &Map.delete(&1, agent_id))
  end

  defp pop_valid(state, depth \\ 0)

  defp pop_valid(state, depth) when depth > 10 do
    valid_agents =
      state.sleepers
      |> Map.keys()
      |> Enum.filter(fn id -> not Map.has_key?(state.dispatched, id) end)

    if valid_agents == [] do
      {:error, :empty, %{state | queue: :queue.new()}}
    else
      {:error, :queue_reset, %{state | queue: :queue.from_list(valid_agents)}}
    end
  end

  defp pop_valid(state, depth) do
    case :queue.out(state.queue) do
      {:empty, _queue} ->
        {:error, :empty, state}

      {{:value, agent_id}, rest} ->
        if Map.has_key?(state.sleepers, agent_id) and not Map.has_key?(state.dispatched, agent_id) do
          {:ok, agent_id, %{state | queue: rest}}
        else
          pop_valid(%{state | queue: rest}, depth + 1)
        end
    end
  end

  defp find_pending_task do
    import Ecto.Query

    Acs.Repo.one(
      from t in Acs.Acs.Task,
        where: t.status == "todo",
        where: is_nil(t.locked_by_agent),
        order_by: [asc: t.inserted_at],
        limit: 1
    )
  end

  defp now, do: DateTime.utc_now()
end
