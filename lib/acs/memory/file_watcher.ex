defmodule Acs.Memory.FileWatcher do
  @moduledoc """
  Watches the memory directory for file changes and
  automatically syncs changed memories to the SQLite index.

  Supports .yaml, .yml, and .md files. Obsidian's .obsidian/
  internal directory is explicitly excluded.

  Uses the :file_system library for platform-independent file watching.
  """

  use GenServer
  require Logger

  @debounce_ms 1000

  @doc """
  Starts the file watcher. Called from the supervision tree.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    dir = Acs.Memory.Loader.memory_dir()

    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} ->
        Logger.warning("[Memory.FileWatcher] Could not create directory #{dir}: #{inspect(reason)}")
    end

    case FileSystem.start_link(dirs: [dir], name: :acs_memory_fs_watcher) do
      {:ok, watcher_pid} ->
        FileSystem.subscribe(watcher_pid)
        Logger.info("[Memory.FileWatcher] Watching #{dir} for memory file changes")
        {:ok, %{watcher_pid: watcher_pid, dir: dir, timer_ref: nil, in_sync: false, pending: false, pending_path: nil}}

      {:error, reason} ->
        Logger.warning("[Memory.FileWatcher] Cannot start file watcher: #{inspect(reason)}. Continuing without file watching.")
        {:ok, %{watcher_pid: nil, dir: dir, timer_ref: nil, in_sync: true, pending: false, pending_path: nil}}

      :ignore ->
        Logger.warning("[Memory.FileWatcher] File system watching not available (inotify unsupported). Continuing without file watching.")
        {:ok, %{watcher_pid: nil, dir: dir, timer_ref: nil, in_sync: true, pending: false, pending_path: nil}}
    end
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, {path, events}}, state) do
    path = to_string(path)

    state =
      if memory_file_event?(path) and not obsidian_path?(path) do
        if state.in_sync do
          Logger.debug("[Memory.FileWatcher] File changed during sync, marking pending")
          %{state | pending: true, pending_path: path}
        else
          Logger.debug("[Memory.FileWatcher] Detected change: #{path} events=#{inspect(events)}")

          if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

          timer_ref = Process.send_after(self(), {:sync, path}, @debounce_ms)
          %{state | timer_ref: timer_ref}
        end
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:file_event, _watcher_pid, :stop}, state) do
    {:noreply, state}
  end

  def handle_info({:sync, path}, state) do
    pid = self()

    Task.start(fn ->
      try do
        case Acs.Memory.Indexer.upsert_memory_file(path) do
          {:ok, memory} ->
            Logger.info("[Memory.FileWatcher] Upserted: #{memory.id} (#{path})")

          {:error, reason} ->
            Logger.warning("[Memory.FileWatcher] Upsert failed for #{path}: #{reason}")
        end
      rescue
        e -> Logger.error("[Memory.FileWatcher] Upsert crashed: #{inspect(e)}")
      end

      send(pid, :sync_complete)
    end)

    {:noreply, %{state | in_sync: true, timer_ref: nil, pending: false, pending_path: nil}}
  end

  def handle_info(:sync_complete, state) do
    if state.pending do
      Logger.debug("[Memory.FileWatcher] Pending sync detected, starting immediately")

      if state.pending_path do
        send(self(), {:sync, state.pending_path})
      else
        Task.start(fn ->
          Acs.Memory.Indexer.sync_all()
        end)

        send(self(), :sync_complete)
      end

      {:noreply, %{state | in_sync: false, pending: false, pending_path: nil}}
    else
      {:noreply, %{state | in_sync: false}}
    end
  end

  # Accept .yaml, .yml, .md files.
  defp memory_file_event?(path) do
    ext = path |> Path.extname() |> String.downcase()
    ext in [".yaml", ".yml", ".md"]
  end

  # Exclude .obsidian/ directory (Obsidian internal config/metadata).
  defp obsidian_path?(path) do
    String.contains?(path, "/.obsidian/")
  end
end
