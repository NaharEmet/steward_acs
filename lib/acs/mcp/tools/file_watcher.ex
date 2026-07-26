defmodule Acs.MCP.Tools.FileWatcher do
  @moduledoc false

  use GenServer
  require Logger

  @debounce_ms 500

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    base = Acs.Org.vault_watch_root()

    if File.dir?(base) do
      case FileSystem.start_link(dirs: [base], name: :acs_mcp_tools_fs_watcher) do
        {:ok, watcher_pid} ->
          FileSystem.subscribe(watcher_pid)
          Logger.info("[MCP.Tools.FileWatcher] Watching #{base} for tenant tool changes")
          {:ok, %{watcher_pid: watcher_pid, base: base, timer_ref: nil}}

        {:error, reason} ->
          Logger.warning("[MCP.Tools.FileWatcher] Cannot start file watcher: #{inspect(reason)}")
          {:ok, %{watcher_pid: nil, base: base, timer_ref: nil}}

        :ignore ->
          Logger.warning("[MCP.Tools.FileWatcher] File system watching is unavailable")
          {:ok, %{watcher_pid: nil, base: base, timer_ref: nil}}
      end
    else
      {:ok, %{watcher_pid: nil, base: base, timer_ref: nil}}
    end
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, {path, _events}}, state) do
    if tenant_tool_file?(to_string(path), state.base) do
      if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
      {:noreply, %{state | timer_ref: Process.send_after(self(), :refresh, @debounce_ms)}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:file_event, _watcher_pid, :stop}, state), do: {:noreply, state}

  def handle_info(:refresh, state) do
    case Acs.MCP.ToolRegistry.refresh() do
      :ok -> :ok
      {:error, reason} -> Logger.warning("[MCP.Tools.FileWatcher] Refresh rejected: #{reason}")
    end

    {:noreply, %{state | timer_ref: nil}}
  end

  @doc false
  def tenant_tool_file?(path, base) do
    relative = Path.relative_to(Path.expand(path), Path.expand(base))

    if Acs.Org.safe_path?(base, path) do
      case Path.split(relative) do
        ["orgs", org, "acstools"] ->
          org in known_orgs()

        ["orgs", org, "acstools", file] ->
          org in known_orgs() and String.downcase(Path.extname(file)) in [".yaml", ".yml"] and
            regular_or_missing?(path)

        _ ->
          false
      end
    else
      false
    end
  end

  defp regular_or_missing?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> true
      {:error, :enoent} -> true
      _ -> false
    end
  end

  defp known_orgs do
    orgs =
      if Acs.Org.multi_tenant?() do
        Acs.Orgs.list_all()
        |> Enum.filter(&(&1.provisioning_status == "ready"))
        |> Enum.map(& &1.slug)
      else
        []
      end

    ([Acs.Org.configured()] ++ orgs)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> MapSet.new()
  end
end
