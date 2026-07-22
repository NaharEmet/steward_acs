defmodule Acs.Observability.AxiomLogExporter do
  @moduledoc """
  Bounded, batched exporter for sending Logger events to Axiom's ingest API.

  Logger callbacks encode directly into a bounded ETS queue. Network I/O runs
  only in this process, so a stalled endpoint cannot block Logger or grow an
  unbounded exporter mailbox.
  """

  use GenServer

  require Logger

  alias Acs.Observability.AxiomLogBackend

  @default_batch_size 100
  @default_flush_interval_ms 5_000
  @default_max_buffer 1_000
  @default_max_buffer_bytes 5_000_000
  @default_max_batch_bytes 1_000_000
  @default_request_timeout_ms 5_000
  @warning_interval_ms 60_000

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 15_000
    }
  end

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :server_name, name), name: name)
  end

  @doc false
  def enqueue(event, server \\ __MODULE__) when is_map(event) do
    with %{table: table, counters: counters} = queue <- queue_config(server),
         {:ok, encoded} <- Jason.encode(event) do
      encoded = encoded <> "\n"
      encoded_size = byte_size(encoded)

      if encoded_size <= queue.max_batch_bytes and :ets.info(table, :size) < queue.max_buffer do
        sequence = System.unique_integer([:monotonic, :positive])
        new_bytes = :atomics.add_get(counters, 1, encoded_size)

        if new_bytes <= queue.max_buffer_bytes do
          true = :ets.insert(table, {sequence, encoded, encoded_size})

          if :ets.info(table, :size) == queue.batch_size,
            do: GenServer.cast(server, :flush_if_due)

          :ok
        else
          :atomics.sub(counters, 1, encoded_size)
          record_drop(counters)
        end
      else
        record_drop(counters)
      end
    else
      _ -> :dropped
    end
  rescue
    _ -> :dropped
  end

  @doc "Drains buffered log batches until empty, failed, or the shutdown deadline is reached."
  def flush(server \\ __MODULE__, timeout \\ 12_000) do
    GenServer.call(server, :flush, timeout)
  catch
    :exit, _ -> {:error, :not_running}
  end

  @impl true
  def init(opts) do
    config =
      :steward_acs
      |> Application.get_env(:axiom, [])
      |> Keyword.merge(opts)

    token = Keyword.fetch!(config, :token)
    dataset = Keyword.fetch!(config, :dataset)
    domain = Keyword.fetch!(config, :domain)
    server_name = Keyword.fetch!(config, :server_name)
    table = :ets.new(__MODULE__, [:ordered_set, :public, read_concurrency: true])
    counters = :atomics.new(2, signed: false)

    state = %{
      server_name: server_name,
      table: table,
      counters: counters,
      endpoint: ingest_endpoint(domain, dataset),
      token: token,
      batch_size: Keyword.get(config, :batch_size, @default_batch_size),
      max_buffer: Keyword.get(config, :max_buffer, @default_max_buffer),
      max_buffer_bytes: Keyword.get(config, :max_buffer_bytes, @default_max_buffer_bytes),
      max_batch_bytes: Keyword.get(config, :max_batch_bytes, @default_max_batch_bytes),
      flush_interval_ms: Keyword.get(config, :flush_interval_ms, @default_flush_interval_ms),
      request_timeout_ms: Keyword.get(config, :request_timeout_ms, @default_request_timeout_ms),
      request_fun: Keyword.get(config, :request_fun, &request/1),
      log_failures: Keyword.get(config, :log_failures, true),
      attach_backend: Keyword.get(config, :attach_backend, true),
      retry_at_ms: nil,
      consecutive_failures: 0,
      last_warning_ms: nil,
      reported_drops: 0
    }

    :persistent_term.put(queue_key(server_name), queue_public_config(state))
    if state.attach_backend, do: send(self(), :attach_backend)
    schedule_flush(state.flush_interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_cast(:flush_if_due, state) do
    {:noreply, if(retry_due?(state), do: flush_batch(state), else: state)}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    deadline_ms = System.monotonic_time(:millisecond) + 10_000
    {state, result} = drain_batches(state, deadline_ms)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:attach_backend, state) do
    case Logger.add_backend(AxiomLogBackend) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_present, _pid}} ->
        :ok

      {:error, :already_present} ->
        :ok

      result ->
        Logger.warning("[AxiomLogExporter] Logger backend attach failed: #{inspect(result)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:flush, state) do
    state = report_drops(state)
    state = if retry_due?(state), do: flush_batch(state), else: state
    schedule_flush(state.flush_interval_ms)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if :ets.info(state.table, :size) > 0, do: perform_request(state, take_batch(state))
    :persistent_term.erase(queue_key(state.server_name))
    if state.attach_backend, do: Logger.remove_backend(AxiomLogBackend)
    :ok
  end

  @impl true
  def format_status(%{state: state} = status) do
    %{status | state: %{state | token: "[REDACTED]", request_fun: "[REDACTED]"}}
  end

  defp drain_batches(state, deadline_ms) do
    cond do
      :ets.info(state.table, :size) == 0 ->
        {state, :ok}

      System.monotonic_time(:millisecond) >= deadline_ms ->
        {state, {:error, :flush_deadline}}

      true ->
        case flush_batch(state, force: true) do
          {state, :ok} -> drain_batches(state, deadline_ms)
          {state, error} -> {state, error}
        end
    end
  end

  defp flush_batch(state, opts \\ []) do
    force? = Keyword.get(opts, :force, false)
    batch = take_batch(state)

    cond do
      batch == [] ->
        if force?, do: {state, :ok}, else: state

      not force? and not retry_due?(state) ->
        state

      true ->
        case perform_request(state, batch) do
          :ok ->
            state = delete_batch(state, batch)
            state = %{state | consecutive_failures: 0, retry_at_ms: nil}
            maybe_continue_flushing(state)
            if force?, do: {state, :ok}, else: state

          {:drop, reason} ->
            state = delete_batch(state, batch)
            state = warn(state, "dropping rejected batch: #{format_reason(reason)}")
            maybe_continue_flushing(state)
            if force?, do: {state, {:error, reason}}, else: state

          {:error, reason} ->
            state = register_failure(state, reason)
            if force?, do: {state, {:error, reason}}, else: state
        end
    end
  end

  defp perform_request(_state, []), do: :ok

  defp perform_request(state, batch) do
    payload = Enum.map_join(batch, "", &elem(&1, 1))

    request = %{
      url: state.endpoint,
      token: state.token,
      body: payload,
      receive_timeout: state.request_timeout_ms
    }

    case state.request_fun.(request) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        if partial_failure?(body), do: {:drop, :partial_ingest_failure}, else: :ok

      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status}} when status in [408, 429] or status >= 500 ->
        {:error, {:http_status, status}}

      {:ok, %{status: status}} ->
        {:drop, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_response, other}}
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp request(request) do
    Req.post(request.url,
      body: request.body,
      headers: [
        {"authorization", "Bearer #{request.token}"},
        {"content-type", "application/x-ndjson"}
      ],
      receive_timeout: request.receive_timeout,
      retry: false
    )
  end

  defp take_batch(state) do
    state.table
    |> :ets.tab2list()
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({[], 0}, fn {_key, _encoded, size} = entry, {batch, bytes} ->
      cond do
        length(batch) >= state.batch_size -> {:halt, {batch, bytes}}
        batch != [] and bytes + size > state.max_batch_bytes -> {:halt, {batch, bytes}}
        true -> {:cont, {[entry | batch], bytes + size}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp delete_batch(state, batch) do
    removed_bytes =
      Enum.reduce(batch, 0, fn {key, _encoded, size}, total ->
        :ets.delete(state.table, key)
        total + size
      end)

    :atomics.sub(state.counters, 1, removed_bytes)
    state
  end

  defp maybe_continue_flushing(state) do
    if :ets.info(state.table, :size) >= state.batch_size,
      do: GenServer.cast(state.server_name, :flush_if_due)
  end

  defp register_failure(state, reason) do
    now = System.monotonic_time(:millisecond)
    failures = state.consecutive_failures + 1
    backoff_ms = min(state.flush_interval_ms * Integer.pow(2, min(failures - 1, 4)), 60_000)

    state
    |> Map.merge(%{consecutive_failures: failures, retry_at_ms: now + backoff_ms})
    |> warn("export failed; bounded queue retained for retry: #{format_reason(reason)}")
  end

  defp report_drops(state) do
    dropped = :atomics.get(state.counters, 2)

    if dropped > state.reported_drops do
      state
      |> Map.put(:reported_drops, dropped)
      |> warn("dropped #{dropped - state.reported_drops} logs because the queue was full")
    else
      state
    end
  end

  defp warn(%{log_failures: false} = state, _message), do: state

  defp warn(state, message) do
    now = System.monotonic_time(:millisecond)

    if is_nil(state.last_warning_ms) or now - state.last_warning_ms >= @warning_interval_ms do
      Logger.warning("[AxiomLogExporter] #{message}", axiom_exporter_internal: true)
      %{state | last_warning_ms: now}
    else
      state
    end
  end

  defp partial_failure?(%{"failed" => failed}) when is_integer(failed), do: failed > 0
  defp partial_failure?(%{failed: failed}) when is_integer(failed), do: failed > 0
  defp partial_failure?(_), do: false

  defp retry_due?(%{retry_at_ms: nil}), do: true
  defp retry_due?(state), do: System.monotonic_time(:millisecond) >= state.retry_at_ms

  defp schedule_flush(interval_ms), do: Process.send_after(self(), :flush, interval_ms)

  defp ingest_endpoint(domain, dataset) do
    encoded_dataset = URI.encode(dataset, &URI.char_unreserved?/1)
    "#{String.trim_trailing(domain, "/")}/v1/ingest/#{encoded_dataset}"
  end

  defp queue_public_config(state) do
    Map.take(state, [
      :table,
      :counters,
      :batch_size,
      :max_buffer,
      :max_buffer_bytes,
      :max_batch_bytes
    ])
  end

  defp queue_config(server), do: :persistent_term.get(queue_key(server), :missing)
  defp queue_key(server), do: {__MODULE__, :queue, server}

  defp record_drop(counters) do
    :atomics.add(counters, 2, 1)
    :dropped
  end

  defp format_reason({:http_status, status}), do: "HTTP #{status}"
  defp format_reason(reason), do: inspect(reason, limit: 5)
end
