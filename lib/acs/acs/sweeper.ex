defmodule Acs.Acs.Sweeper do
  use GenServer
  require Logger

  alias Acs.Repo
  alias Acs.Acs.Task, as: AcsTask
  alias Acs.Acs.FileLock
  alias Acs.Acs.AgentStatus
  alias Acs.Acs.Cache
  import Ecto.Query

  @sweep_interval 60_000

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Triggers an immediate sweep. Used on app startup.
  """
  def sweep_now do
    GenServer.cast(__MODULE__, :sweep)
  end

  @impl true
  def init(_opts) do
    Logger.info("[Acs.Sweeper] Starting auto-release sweeper")
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    do_sweep()
    schedule_sweep()
    {:noreply, state}
  end

  @impl true
  def handle_cast(:sweep, state) do
    do_sweep()
    {:noreply, state}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval)
  end

  defp do_sweep do
    Logger.info("[Acs.Sweeper] Running sweep")

    now = DateTime.utc_now()

    # Find and release expired task locks
    expired_tasks =
      Repo.all(
        from t in AcsTask,
          where: not is_nil(t.auto_release_at),
          where: t.auto_release_at < ^now
      )

    Enum.each(expired_tasks, fn task ->
      Logger.info("[Acs.Sweeper] Auto-releasing expired task: #{task.id}")
      release_task_lock(task)
    end)

    # Find and delete expired file locks
    expired_files =
      Repo.all(
        from f in FileLock,
          where: not is_nil(f.auto_release_at),
          where: f.auto_release_at < ^now
      )

    Enum.each(expired_files, fn lock ->
      Logger.info("[Acs.Sweeper] Auto-releasing expired file lock: #{lock.file_path}")
      Repo.delete(lock)
      Cache.delete_file_lock(lock.file_path)
      Acs.broadcast(:file_unlocked, %{file_path: lock.file_path})
    end)

    Logger.info(
      "[Acs.Sweeper] Sweep complete: #{length(expired_tasks)} tasks, #{length(expired_files)} file locks released"
    )
  end

  defp release_task_lock(task) do
    original_agent = task.locked_by_agent

    # Guard: Skip if task is already released or already done.
    if is_nil(task.locked_by_agent) or task.status == "done" do
      Logger.info("[Acs.Sweeper] Task #{task.id} already released/done, skipping")
      :skip
    else
      result =
        Repo.transaction(fn ->
          # Re-read with FOR UPDATE lock to prevent race with agent release
          locked_task = Repo.get!(AcsTask, task.id, lock: "FOR UPDATE")

          if is_nil(locked_task.locked_by_agent) or locked_task.status == "done" do
            Repo.rollback(:skip)
          end

          {:ok, updated} =
            locked_task
            |> AcsTask.changeset(%{
              "locked_by_agent" => nil,
              "locked_at" => nil,
              "auto_release_at" => nil,
              "status" => "done"
            })
            |> Repo.update()

          Cache.put_task(updated.id, %{
            id: updated.id,
            title: updated.title,
            description: updated.description,
            status: updated.status,
            created_by_agent: updated.created_by_agent,
            locked_by_agent: nil,
            locked_at: nil,
            auto_release_at: nil,
            file_paths: updated.file_paths || []
          })

          # Cascade release all file locks for this task
          locks = Repo.all(from f in FileLock, where: f.task_id == ^task.id)

          Enum.each(locks, fn lock ->
            Repo.delete(lock)
            Cache.delete_file_lock(lock.file_path)
          end)

          # Clear agent status if it was set
          if original_agent do
            case Repo.get(AgentStatus, original_agent) do
              nil ->
                :ok

              status ->
                case Repo.delete(status) do
                  {:ok, _} ->
                    Cache.delete_agent_status(original_agent)

                  {:error, _} ->
                    Logger.warning(
                      "[Acs.Sweeper] Failed to delete agent status for #{original_agent}"
                    )

                    Cache.delete_agent_status(original_agent)
                end
            end
          end

          {:ok, updated}
        end)

      case result do
        {:ok, {:ok, updated}} ->
          Acs.broadcast(:task_released, %{task_id: updated.id, agent_id: original_agent})
          Acs.broadcast(:file_unlocked, %{task_id: updated.id})

          if original_agent do
            Acs.broadcast(:agent_removed, %{agent_id: original_agent})
          end

          :ok

        {:error, :skip} ->
          :skip

        {:error, reason} ->
          Logger.warning(
            "[Acs.Sweeper] Transaction failed for task #{task.id}: #{inspect(reason)}"
          )

          :error
      end
    end
  end
end
