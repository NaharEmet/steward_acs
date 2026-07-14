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
  def register(agent_id, timeout \\ :infinity, org \\ Acs.Org.current()) do
    GenServer.call(@name, {:register, org, agent_id, timeout}, :infinity)
  end

  @doc """
  Unregisters a sleeping agent. Returns `:ok`.
  """
  def unregister(agent_id, org \\ Acs.Org.current()) do
    GenServer.call(@name, {:unregister, {org, agent_id}})
  end

  @doc """
  Pops the next waiting agent from the queue and dispatches the given task.

  Returns `{:ok, agent_id, task_id}` on successful dispatch.
  Returns `{:error, :no_sleeping_agents}` if queue is empty.
  """
  def try_dispatch(task_id, org \\ Acs.Org.current()) do
    GenServer.call(@name, {:try_dispatch, org, task_id})
  end

  @doc """
  Manually wakes a sleeping agent via cancellation.
  Returns `{:ok, :cancelled}` or `{:error, :not_sleeping}`.
  """
  def wake_agent(agent_id, org \\ Acs.Org.current()) do
    GenServer.call(@name, {:wake_agent, {org, agent_id}})
  end

  @doc """
  Returns list of currently sleeping agents.
  Each entry: `%{agent_id: string, registered_at: DateTime, timeout: integer | :infinity}`
  """
  def list_sleeping_agents(org \\ Acs.Org.current()) do
    GenServer.call(@name, {:list_sleeping_agents, org})
  end

  # ──────────────────────────── GenServer Callbacks ────────────────────────────

  @impl true
  def init(_opts) do
    Logger.info("[SleepRegistry] Starting...")
    {:ok, %{sleepers: %{}, queue: :queue.new(), dispatched: %{}}}
  end

  @impl true
  def handle_call({:register, org, agent_id, timeout}, {pid, _tag} = _from, state) do
    key = {org, agent_id}
    # Clean any stale dispatched entry from a prior dispatch cycle
    state = %{state | dispatched: Map.delete(state.dispatched, key)}

    if Map.has_key?(state.sleepers, key) do
      {:reply, {:error, :already_sleeping}, state}
    else
      ref = make_ref()
      Process.monitor(pid)

      # Check for pending unassigned todo tasks
      pending_task =
        try do
          find_pending_task(org)
        rescue
          e ->
            Logger.error("[SleepRegistry] Failed to find pending task: #{inspect(e)}")
            nil
        end

      case pending_task do
        nil ->
          sleeper = %{
            agent_id: agent_id,
            org: org,
            pid: pid,
            ref: ref,
            timeout: timeout,
            registered_at: now()
          }

          sleepers = Map.put(state.sleepers, key, sleeper)
          queue = :queue.in(key, state.queue)

          Logger.info(
            "[SleepRegistry] Agent #{agent_id} sleeping (queue depth: #{:queue.len(queue)})"
          )

          {:reply, {:ok, ref, :enqueued}, %{state | sleepers: sleepers, queue: queue}}

        task ->
          send(pid, {:task_assigned, ref, task.id})
          dispatched = Map.put(state.dispatched, key, task.id)
          Logger.info("[SleepRegistry] Agent #{agent_id} dispatched pending task #{task.id}")
          {:reply, {:ok, ref, :immediate, task.id}, %{state | dispatched: dispatched}}
      end
    end
  end

  @impl true
  def handle_call({:unregister, key}, _from, state) do
    {:reply, :ok, do_unregister(state, key)}
  end

  @impl true
  def handle_call({:try_dispatch, org, task_id}, _from, state) do
    case pop_valid(state, org) do
      {:error, :empty, state} ->
        {:reply, {:error, :no_sleeping_agents}, state}

      {:error, :queue_reset, state} ->
        {:reply, {:error, :no_sleeping_agents}, state}

      {:ok, key, state} ->
        sleeper = Map.fetch!(state.sleepers, key)
        send(sleeper.pid, {:task_assigned, sleeper.ref, task_id})
        dispatched = Map.put(state.dispatched, key, task_id)
        state = do_unregister(state, key)
        Logger.info("[SleepRegistry] Dispatched task #{task_id} to agent #{sleeper.agent_id}")
        {:reply, {:ok, sleeper.agent_id, task_id}, %{state | dispatched: dispatched}}
    end
  end

  @impl true
  def handle_call({:wake_agent, key}, _from, state) do
    case Map.fetch(state.sleepers, key) do
      {:ok, sleeper} ->
        send(sleeper.pid, {:cancelled, sleeper.ref})
        state = do_unregister(state, key)
        Logger.info("[SleepRegistry] Manual wake of agent #{sleeper.agent_id}")
        {:reply, {:ok, :cancelled}, state}

      :error ->
        {:reply, {:error, :not_sleeping}, state}
    end
  end

  @impl true
  def handle_call({:list_sleeping_agents, org}, _from, state) do
    agents =
      state.sleepers
      |> Enum.filter(fn {{sleeper_org, _id}, _sleeper} -> sleeper_org == org end)
      |> Enum.map(fn {_key, sleeper} ->
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
    key =
      Enum.find_value(state.sleepers, fn {sleeper_key, sleeper} ->
        if sleeper.pid == pid, do: sleeper_key, else: nil
      end)

    case key do
      nil ->
        {:noreply, state}

      {_org, agent_id} = sleeper_key ->
        Logger.info("[SleepRegistry] Agent #{agent_id} process exited: #{inspect(reason)}")
        {:noreply, do_unregister(state, sleeper_key)}
    end
  end

  # ──────────────────────────── Private ────────────────────────────

  defp do_unregister(state, key) do
    state
    |> Map.update!(:sleepers, &Map.delete(&1, key))
    |> Map.update!(:dispatched, &Map.delete(&1, key))
  end

  defp pop_valid(state, org, depth \\ 0)

  defp pop_valid(state, org, depth) when depth > 10 do
    valid_agents =
      state.sleepers
      |> Map.keys()
      |> Enum.filter(fn {sleeper_org, _id} = key ->
        sleeper_org == org and not Map.has_key?(state.dispatched, key)
      end)

    if valid_agents == [] do
      {:error, :empty, %{state | queue: :queue.new()}}
    else
      {:error, :queue_reset, %{state | queue: :queue.from_list(valid_agents)}}
    end
  end

  defp pop_valid(state, org, depth) do
    case :queue.out(state.queue) do
      {:empty, _queue} ->
        {:error, :empty, state}

      {{:value, {sleeper_org, _id} = key}, rest} ->
        cond do
          sleeper_org != org ->
            pop_valid(%{state | queue: :queue.in(key, rest)}, org, depth + 1)

          Map.has_key?(state.sleepers, key) and not Map.has_key?(state.dispatched, key) ->
            {:ok, key, %{state | queue: rest}}

          true ->
            pop_valid(%{state | queue: rest}, org, depth + 1)
        end
    end
  end

  defp find_pending_task(org) do
    import Ecto.Query

    Acs.Repo.one(
      from t in Acs.Acs.Task,
        where: t.org == ^org,
        where: t.status == "todo",
        where: is_nil(t.locked_by_agent),
        order_by: [asc: t.inserted_at],
        limit: 1
    )
  end

  defp now, do: DateTime.utc_now()
end
