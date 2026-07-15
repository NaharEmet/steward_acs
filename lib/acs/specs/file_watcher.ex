defmodule Acs.Specs.FileWatcher do
  @moduledoc """
  Watches the specs directory for file changes and broadcasts
  `:specs_updated` on the "acs" PubSub topic so LiveViews reload
  without a manual refresh.

  Specs are loaded from disk on demand (no DB index), so the watcher
  only needs to notify subscribers — no re-indexing is required.

  Supports .yaml, .yml, and .md files. Obsidian's .obsidian/
  internal directory is explicitly excluded. Events are debounced
  so bulk writes produce a single broadcast.
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
    dir =
      if Acs.Org.multi_tenant?() do
        Acs.Org.vault_watch_root()
      else
        Acs.Specs.Loader.specs_path()
      end

    case File.mkdir_p(dir) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Specs.FileWatcher] Could not create directory #{dir}: #{inspect(reason)}"
        )
    end

    case FileSystem.start_link(dirs: [dir], name: :acs_specs_fs_watcher) do
      {:ok, watcher_pid} ->
        FileSystem.subscribe(watcher_pid)
        Logger.info("[Specs.FileWatcher] Watching #{dir} for spec file changes")
        {:ok, %{watcher_pid: watcher_pid, dir: dir, timer_ref: nil}}

      {:error, reason} ->
        Logger.warning(
          "[Specs.FileWatcher] Cannot start file watcher: #{inspect(reason)}. Continuing without file watching."
        )

        {:ok, %{watcher_pid: nil, dir: dir, timer_ref: nil}}

      :ignore ->
        Logger.warning(
          "[Specs.FileWatcher] File system watching not available (inotify unsupported). Continuing without file watching."
        )

        {:ok, %{watcher_pid: nil, dir: dir, timer_ref: nil}}
    end
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, {path, events}}, state) do
    path = to_string(path)

    state =
      if spec_file_event?(path) and not obsidian_path?(path) do
        Logger.debug("[Specs.FileWatcher] Detected change: #{path} events=#{inspect(events)}")

        if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

        timer_ref = Process.send_after(self(), :broadcast, @debounce_ms)
        %{state | timer_ref: timer_ref}
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:file_event, _watcher_pid, :stop}, state) do
    {:noreply, state}
  end

  def handle_info(:broadcast, state) do
    Acs.broadcast(:specs_updated, %{})
    {:noreply, %{state | timer_ref: nil}}
  end

  # Accept .yaml, .yml, .md files.
  defp spec_file_event?(path) do
    ext = path |> Path.extname() |> String.downcase()
    ext in [".yaml", ".yml", ".md"]
  end

  # Exclude .obsidian/ directory (Obsidian internal config/metadata).
  defp obsidian_path?(path) do
    String.contains?(path, "/.obsidian/")
  end
end
