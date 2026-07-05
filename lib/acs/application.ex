defmodule Acs.Application do
  @moduledoc false
  # Standard OTP Application callback. Starts the ACS supervision tree
  # including Repo, MCP ToolRegistry, memory system (cache, sweeper,
  # auditor, indexer), log store, web endpoint, and background tasks
  # for file watching and retention sweeping.
  use Application

  require Logger

  @impl true
  def stop(_state) do
    if meta_harness_enabled?(), do: Acs.MetaHarness.OperationLogger.flush()
    :ok
  end

  @impl true
  def start(_type, _args) do
    env_path = System.get_env("ENV_PATH") || Path.expand("../../.env", __DIR__)
    if File.exists?(env_path), do: Dotenvy.source!(env_path)

    meta_harness_children =
      if meta_harness_enabled?() do
        [Acs.MetaHarness.OperationLogger, Acs.MetaHarness.Scheduler]
      else
        []
      end

    children =
      [
        Acs.Apps.Config,
        Acs.Repo | meta_harness_children
      ] ++
        [
          Acs.Acs.Cache,
          Acs.Acs.Sweeper,
          Acs.Acs.SleepRegistry,
          Acs.MCP.ToolRegistry,
          Acs.MCP.SSESessionManager,
          Acs.MCP.LogStore,
          Acs.MCP.ErrorTrace,
          Acs.LogAnalyzer,
          # Acs.MCP.Server removed — endpoint handles MCP routing (start_http/1 available for standalone)
          {Phoenix.PubSub, name: AcsWeb.PubSub},
          AcsWeb.Endpoint
        ]

    # Only start file watcher and retention sweeper in non-test environments
    # to avoid background tasks conflicting with Ecto sandbox connections.
    children =
      if Application.get_env(:steward_acs, :start_background_workers, true) do
        [Acs.Memory.Auditor, Acs.Memory.FileWatcher, {Acs.Log.RetentionSweeper, []}, Acs.Skills.Auditor | children]
      else
        children
      end

    opts = [strategy: :one_for_one, name: Acs.Supervisor]
    {:ok, pid} = Supervisor.start_link(children, opts)

    # Initial sync: populate SQLite index from YAML files on boot.
    # Only runs when background workers are enabled (not in test)
    # to avoid Ecto sandbox conflicts with background DB queries.
    if Application.get_env(:steward_acs, :start_background_workers, true) do
      Task.start(fn ->
        {:ok, count, quarantined} = Acs.Memory.Indexer.sync_all()

        if quarantined != [] do
          Logger.warning(
            "[Application] Initial memory sync: #{count} indexed, #{length(quarantined)} quarantined"
          )
        else
          Logger.info("[Application] Initial memory sync: #{count} memories indexed")
        end

        case Acs.Memory.Embedding.ensure_embeddings() do
          {:ok, stats} ->
            Logger.info(
              "[Application] Embedding generation: #{stats.embedded} new, #{stats.existing} existing, #{stats.failed} failed out of #{stats.total}"
            )

          {:error, reason} ->
            Logger.warning("[Application] Embedding generation skipped: #{reason}")
        end
      end)

      # Warmup ACS ETS cache from database after startup.
      Task.start(fn ->
        Process.sleep(100)
        Acs.Acs.Cache.warmup()
      end)
    end

    {:ok, pid}
  end

  defp meta_harness_enabled? do
    System.get_env("META_HARNESS_ENABLED", "false") == "true"
  end
end
