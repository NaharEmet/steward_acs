defmodule Acs.Memory.FileWatcher do
  @moduledoc """
  Watches the priv/acs_memory/ directory for file changes and
  automatically syncs changed memories to the SQLite index.

  Uses the :file_system library for platform-independent file watching.
  """

  use GenServer
  require Logger

  @doc """
  Starts the file watcher. Called from the supervision tree.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    dir = Acs.Memory.Loader.memory_dir()

    # Ensure directory exists — use non-bang to avoid crashing on permission errors
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} ->
        Logger.warning("[Memory.FileWatcher] Could not create directory #{dir}: #{inspect(reason)}")
    end

    # Start the FileSystem watcher
    {:ok, watcher_pid} = FileSystem.start_link(dirs: [dir], name: :acs_memory_fs_watcher)
    FileSystem.subscribe(watcher_pid)

    Logger.info("[Memory.FileWatcher] Watching #{dir} for memory file changes")
    {:ok, %{watcher_pid: watcher_pid, dir: dir, timer_ref: nil, in_sync: false, pending: false}}
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, {path, events}}, state) do
    path = to_string(path)

    state =
      if String.ends_with?(path, ".yaml") do
        if state.in_sync do
          Logger.debug("[Memory.FileWatcher] YAML changed during sync, marking pending")
          %{state | pending: true}
        else
          Logger.debug("[Memory.FileWatcher] Detected change: #{path} events=#{inspect(events)}")

          # Cancel previous debounce timer
          if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

          # Schedule sync in 500ms to debounce rapid changes
          timer_ref = Process.send_after(self(), :sync, 500)
          %{state | timer_ref: timer_ref}
        end
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info(:sync, state) do
    pid = self()

    Task.start(fn ->
      try do
        case Acs.Memory.Indexer.sync_all() do
          {:ok, count, quarantined} ->
            if quarantined != [] do
              Logger.warning(
                "[Memory.FileWatcher] Sync complete: #{count} indexed, #{length(quarantined)} quarantined"
              )
            else
              Logger.info("[Memory.FileWatcher] Sync complete: #{count} memories indexed")
            end
        end
      rescue
        e -> Logger.error("[Memory.FileWatcher] sync_all crashed: #{inspect(e)}")
      end

      send(pid, :sync_complete)
    end)

    {:noreply, %{state | in_sync: true, timer_ref: nil, pending: false}}
  end

  @impl true
  def handle_info(:sync_complete, state) do
    if state.pending do
      Logger.debug("[Memory.FileWatcher] Pending sync detected, starting immediately")
      send(self(), :sync)
      {:noreply, %{state | in_sync: false, pending: false}}
    else
      {:noreply, %{state | in_sync: false}}
    end
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, :stop}, state) do
    {:noreply, state}
  end
end
