defmodule Acs.MetaHarness.OperationLogger do
  @moduledoc """
  Async Operation Logger for ACS Meta-Harness.

  Records every tool invocation with latency, success/failure status,
  and error details. Uses an in-memory buffer and periodic flush
  to avoid adding latency to the tool call hot path.

  ## Usage

      # Async (preferred - fire and forget)
      Acs.MetaHarness.OperationLogger.log_async("lock_file", :success, 12, nil, nil, "Alice", nil)

      # Sync (use only when you must wait)
      Acs.MetaHarness.OperationLogger.log("create_work", :failure, 8, "task_exists", "Task already exists", "Bob", nil)
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
      inserted_at: DateTime.utc_now() |> Calendar.strftime("%Y-%m-%d %H:%M:%S")
    }

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
  Logs a tool operation synchronously.

  Use `log_async/8` in the hot path. This version waits for the
  database write and should only be used when you must ensure
  the log is persisted before continuing.
  """
  @spec log(
          String.t(),
          atom(),
          integer() | nil,
          String.t() | nil,
          String.t() | nil,
          String.t() | nil,
          String.t() | nil,
          keyword()
        ) :: :ok
  def log(
        tool_name,
        status,
        latency_ms,
        error_type \\ nil,
        error_message \\ nil,
        agent_id \\ nil,
        execution_id \\ nil,
        opts \\ []
      ) do
    attrs = %{
      "tool_name" => tool_name,
      "status" => Atom.to_string(status),
      "latency_ms" => latency_ms,
      "error_type" => error_type,
      "error_message" => error_message && String.slice(error_message, 0, 1000),
      "agent_id" => agent_id,
      "execution_id" => execution_id,
      "execution_chain_id" => Keyword.get(opts, :execution_chain_id),
      "sequence_order" => Keyword.get(opts, :sequence_order, 0),
      "attempt" => Keyword.get(opts, :attempt, 1),
      "tool_discovered" => Keyword.get(opts, :tool_discovered, false),
      "error_burst" => Keyword.get(opts, :error_burst, false),
      "params_hash" => Keyword.get(opts, :params_hash)
    }

    if Code.ensure_loaded?(Acs.Repo) and function_exported?(Acs.Repo, :transaction, 1) do
      try do
        Acs.Repo.transaction(fn ->
          Ecto.Adapters.SQL.query(
            Acs.Repo,
            """
              INSERT INTO acs_tool_operations (tool_name, status, latency_ms, error_type, error_message, agent_id, execution_id, execution_chain_id, sequence_order, attempt, tool_discovered, error_burst, params_hash, created_at)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
            """,
            [
              attrs["tool_name"],
              attrs["status"],
              attrs["latency_ms"],
              attrs["error_type"],
              attrs["error_message"],
              attrs["agent_id"],
              attrs["execution_id"],
              attrs["execution_chain_id"],
              attrs["sequence_order"],
              attrs["attempt"],
              attrs["tool_discovered"],
              attrs["error_burst"],
              attrs["params_hash"]
            ]
          )
        end)

        :ok
      rescue
        e ->
          Logger.warning("[OperationLogger] Failed to log operation: #{inspect(e)}")
          :ok
      end
    else
      :ok
    end
  end

  @doc """
  Logs a tool call result by extracting status from the result tuple.
  """
  @spec log_tool_result_async(
          String.t(),
          term(),
          integer() | nil,
          String.t() | nil,
          String.t() | nil,
          keyword()
        ) :: :ok
  def log_tool_result_async(
        tool_name,
        result,
        latency_ms,
        agent_id \\ nil,
        execution_id \\ nil,
        opts \\ []
      ) do
    {status, error_type, error_message} = extract_result_info(result)

    log_async(
      tool_name,
      status,
      latency_ms,
      error_type,
      error_message,
      agent_id,
      execution_id,
      opts
    )
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
        Acs.Repo.transaction(fn ->
          Enum.each(buffer, fn entry ->
            Ecto.Adapters.SQL.query(
              Acs.Repo,
              """
                INSERT INTO acs_tool_operations (tool_name, status, latency_ms, error_type, error_message, agent_id, execution_id, execution_chain_id, sequence_order, attempt, tool_discovered, error_burst, params_hash, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
          end)
        end)

        :ok
      rescue
        e ->
          Logger.warning("[OperationLogger] Flush failed: #{inspect(e)}")
          {:error, e}
      end
    else
      {:error, :repo_not_available}
    end
  end

  defp extract_result_info({:ok, _}) do
    {:success, nil, nil}
  end

  defp extract_result_info(:ok) do
    {:success, nil, nil}
  end

  defp extract_result_info({:sleep, _, _}) do
    {:success, nil, nil}
  end

  defp extract_result_info({:error, reason}) when is_binary(reason) do
    error_type = String.slice(reason, 0, 50)
    {:failure, error_type, reason}
  end

  defp extract_result_info({:error, %{reason: reason}}) do
    error_type = String.slice(reason, 0, 50)
    {:failure, error_type, reason}
  end

  defp extract_result_info({:error, reason}) do
    error_type = inspect(reason) |> String.slice(0, 50)
    {:failure, error_type, inspect(reason)}
  end

  defp extract_result_info(other) do
    {:unknown, "unexpected_result", inspect(other)}
  end
end
