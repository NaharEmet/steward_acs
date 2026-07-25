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
    dirs = watch_dirs() |> Enum.filter(&File.dir?/1)

    case dirs do
      [] ->
        Logger.info("[Specs.FileWatcher] No provisioned specs directories to watch")
        {:ok, %{watcher_pid: nil, dirs: [], timer_ref: nil}}

      _ ->
        start_watcher(dirs)
    end
  end

  defp start_watcher(dirs) do
    case FileSystem.start_link(dirs: dirs, name: :acs_specs_fs_watcher) do
      {:ok, watcher_pid} ->
        FileSystem.subscribe(watcher_pid)
        Logger.info("[Specs.FileWatcher] Watching #{Enum.join(dirs, ", ")} for spec file changes")
        {:ok, %{watcher_pid: watcher_pid, dirs: dirs, timer_ref: nil}}

      {:error, reason} ->
        Logger.warning(
          "[Specs.FileWatcher] Cannot start file watcher: #{inspect(reason)}. Continuing without file watching."
        )

        {:ok, %{watcher_pid: nil, dirs: dirs, timer_ref: nil}}

      :ignore ->
        Logger.warning(
          "[Specs.FileWatcher] File system watching not available (inotify unsupported). Continuing without file watching."
        )

        {:ok, %{watcher_pid: nil, dirs: dirs, timer_ref: nil}}
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

  defp watch_dirs do
    [Acs.Org.vault_base() || Acs.Specs.Loader.specs_path(), Acs.Specs.Loader.specs_path()]
    |> Enum.uniq()
  end

  @doc false
  # Accept .yaml, .yml, .md files only from spec roots.
  def spec_file_event?(path) do
    ext = path |> Path.extname() |> String.downcase()
    ext in [".yaml", ".yml", ".md"] and spec_path?(path)
  end

  defp spec_path?(path) do
    case Acs.Org.org_from_vault_path(path) do
      org when is_binary(org) ->
        path_within?(path, Acs.Org.specs_dir(org)) or
          Enum.any?(Acs.Org.legacy_specs_dirs(org), &path_within?(path, &1))

      nil ->
        path_within?(path, Acs.Specs.Loader.specs_path())
    end
  end

  defp path_within?(path, root), do: Acs.Org.safe_path?(root, path)

  # Exclude .obsidian/ directory (Obsidian internal config/metadata).
  defp obsidian_path?(path) do
    String.contains?(path, "/.obsidian/")
  end
end
