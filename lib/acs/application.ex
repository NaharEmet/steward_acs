defmodule Acs.Application do
  @moduledoc false
  # Standard OTP Application callback. Starts the ACS supervision tree
  # including Repo, MCP ToolRegistry, memory system (cache, sweeper,
  # auditor, indexer), log store, web endpoint, and background tasks
  # for file watching and retention sweeping.
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    # Load .env file for API keys
    Dotenvy.source!(Path.expand("../../.env", __DIR__))

    children = [
      Acs.Repo,
      Acs.MetaHarness.OperationLogger,
      Acs.MetaHarness.Scheduler,
      Acs.Acs.Cache,
      Acs.Acs.Sweeper,
      Acs.Memory.Auditor,
      Acs.Acs.SleepRegistry,
      Acs.MCP.ToolRegistry,
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
      if Mix.env() != :test do
        [Acs.Memory.FileWatcher, {Acs.Log.RetentionSweeper, []} | children]
      else
        children
      end

    opts = [strategy: :one_for_one, name: Acs.Supervisor]
    {:ok, pid} = Supervisor.start_link(children, opts)

    # Initial sync: populate SQLite index from YAML files on boot.
    # Runs async so it doesn't block startup. sync_all/0 always returns
    # {:ok, count, quarantined} — errors are logged internally.
    Task.start(fn ->
      {:ok, count, quarantined} = Acs.Memory.Indexer.sync_all()

      if quarantined != [] do
        Logger.warning(
          "[Application] Initial memory sync: #{count} indexed, #{length(quarantined)} quarantined"
        )
      else
        Logger.info("[Application] Initial memory sync: #{count} memories indexed")
      end

      # Generate embeddings for memories that don't have one yet
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
    # Only runs in non-test to avoid Ecto sandbox conflicts with background DB queries.
    if Mix.env() != :test do
      Task.start(fn ->
        Process.sleep(100)
        Acs.Acs.Cache.warmup()
      end)
    end

    {:ok, pid}
  end
end
