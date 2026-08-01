defmodule Acs.MetaHarness.OperationLogger do
  @moduledoc """
  Async Operation Logger for ACS Meta-Harness.

  Records every tool invocation with latency, success/failure status,
  and error details. Uses an in-memory buffer and periodic flush
  to avoid adding latency to the tool call hot path.

  ## Usage

      Acs.MetaHarness.OperationLogger.log_async("lock_file", :success, 12, nil, nil, "Alice", nil)
  """

  use GenServer
  require Logger

  @flush_interval :timer.seconds(5)
  @max_buffer_size 100
  # Backpressure cap to prevent OOM
  @max_buffer_cap 1000
  @max_consecutive_failures 3

  # ── Client API ──────────────────────────────────────────────────────────────

  @doc """
  Starts the OperationLogger GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Logs a tool operation asynchronously (fire-and-forget).

  The log entry is buffered and flushed to SQLite periodically
  or when the buffer reaches #{@max_buffer_size} entries.
  """
  @spec log_async(
          String.t(),
          atom(),
          integer() | nil,
          String.t() | nil,
          String.t() | nil,
          String.t() | nil,
          String.t() | nil,
          keyword()
        ) :: :ok
  def log_async(
        tool_name,
        status,
        latency_ms,
        error_type \\ nil,
        error_message \\ nil,
        agent_id \\ nil,
        execution_id \\ nil,
        opts \\ []
      ) do
    entry = %{
      tool_name: tool_name,
      status: Atom.to_string(status),
      latency_ms: latency_ms,
      error_type: error_type,
      error_message: error_message && String.slice(error_message, 0, 1000),
      agent_id: agent_id,
      execution_id: execution_id,
      execution_chain_id: Keyword.get(opts, :execution_chain_id),
      sequence_order: Keyword.get(opts, :sequence_order, 0),
      attempt: Keyword.get(opts, :attempt, 1),
      tool_discovered: Keyword.get(opts, :tool_discovered, false),
      error_burst: Keyword.get(opts, :error_burst, false),
      params_hash: Keyword.get(opts, :params_hash),
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    # Always keep an in-memory copy for Analyzer fallback (Axiom ingest can't query).
    Acs.MetaHarness.RecentOps.record(entry)

    if Code.ensure_loaded?(Acs.Repo) and function_exported?(Acs.Repo, :transaction, 1) do
      if Process.whereis(__MODULE__) do
        send(__MODULE__, {:buffer, entry})
      else
        Logger.warning("[OperationLogger] Logger not running, dropping log entry")
      end
    end

    :ok
  end

  @doc """
  Returns the current buffer size for monitoring.
  """
  @spec buffer_size() :: non_neg_integer()
  def buffer_size do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :buffer_size)
    else
      0
    end
  end

  @doc """
  Forces a flush of the buffer to the database.
  Useful for testing or when shutting down.
  """
  @spec flush() :: :ok
  def flush do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :flush)
    else
      :ok
    end
  end

  # ── Server Callbacks ─────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    schedule_flush()
    {:ok, %{buffer: [], buffer_size: 0, consecutive_failures: 0}}
  end

  @impl true
  def handle_call(:buffer_size, _from, %{buffer_size: size} = state) do
    {:reply, size, state}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    case flush_buffer(state.buffer) do
      :ok -> {:reply, :ok, %{state | buffer: [], buffer_size: 0}}
      {:error, _} -> {:reply, :error, state}
    end
  end

  @impl true
  def handle_info({:buffer, entry}, %{buffer: buffer, buffer_size: size} = state) do
    new_buffer = [entry | buffer]
    new_size = size + 1

    if new_size >= @max_buffer_size do
      _ = flush_buffer(new_buffer)
      {:noreply, %{state | buffer: [], buffer_size: 0}}
    else
      {:noreply, %{state | buffer: new_buffer, buffer_size: new_size}}
    end
  end

  @impl true
  def handle_info(:flush, %{buffer: buffer, consecutive_failures: failures} = state) do
    case flush_buffer(buffer) do
      :ok ->
        if failures > 0 do
          Logger.info("[OperationLogger] Flush recovered after #{failures} consecutive failures")
        end

        schedule_flush()
        {:noreply, %{state | buffer: [], buffer_size: 0, consecutive_failures: 0}}

      {:error, reason} ->
        new_failures = failures + 1

        if new_failures > @max_consecutive_failures do
          Logger.error(
            "[OperationLogger] #{new_failures} consecutive flush failures: #{inspect(reason)}"
          )
        else
          Logger.warning("[OperationLogger] Flush failed (##{new_failures}): #{inspect(reason)}")
        end

        # Cap buffer to prevent OOM on persistent DB failure
        dropped = max(0, length(buffer) - @max_buffer_cap)

        if dropped > 0 do
          Logger.warning(
            "[OperationLogger] Dropping #{dropped} oldest entries (buffer cap #{@max_buffer_cap})"
          )
        end

        capped = Enum.take(buffer, @max_buffer_cap)
        capped_size = length(capped)
        schedule_flush()

        {:noreply,
         %{state | buffer: capped, buffer_size: capped_size, consecutive_failures: new_failures}}
    end
  end

  # ── Private Functions ───────────────────────────────────────────────────────

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval)
  end

  defp flush_buffer([]) do
    :ok
  end

  defp flush_buffer(buffer) when is_list(buffer) do
    if Code.ensure_loaded?(Acs.Repo) and function_exported?(Acs.Repo, :transaction, 1) do
      try do
        case Acs.Repo.transaction(fn ->
               Enum.each(buffer, fn entry ->
                 case insert_operation(entry) do
                   {:ok, _} ->
                     :ok

                   {:error, reason} ->
                     # Fail the transaction — previously {:error,_} was ignored and flushes
                     # looked successful while Neon stayed empty (missing id serial).
                     Acs.Repo.rollback(reason)
                 end
               end)

               :ok
             end) do
          {:ok, :ok} -> :ok
          {:error, reason} -> {:error, reason}
        end
      rescue
        e ->
          Logger.warning("[OperationLogger] Flush failed: #{inspect(e)}")
          {:error, e}
      end
    else
      {:error, :repo_not_available}
    end
  end

  defp insert_operation(entry) do
    ph = Acs.MetaHarness.SQL.placeholders(14)

    Ecto.Adapters.SQL.query(
      Acs.Repo,
      """
        INSERT INTO acs_tool_operations (tool_name, status, latency_ms, error_type, error_message, agent_id, execution_id, execution_chain_id, sequence_order, attempt, tool_discovered, error_burst, params_hash, created_at)
        VALUES (#{ph})
      """,
      [
        entry.tool_name,
        entry.status,
        entry.latency_ms,
        entry.error_type,
        entry.error_message,
        entry.agent_id,
        entry.execution_id,
        entry.execution_chain_id,
        entry.sequence_order,
        entry.attempt,
        entry.tool_discovered,
        entry.error_burst,
        entry.params_hash,
        entry.inserted_at
      ]
    )
  end
end
