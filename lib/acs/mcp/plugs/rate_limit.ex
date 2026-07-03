defmodule Acs.MCP.Plugs.RateLimit do
  @moduledoc """
  Sliding-window rate limiter for MCP/API HTTP routes.

  Keys prefer a hashed API key when present, falling back to client IP.
  Uses atomic ETS counters per window bucket.
  """
  import Plug.Conn

  @table :acs_rate_limit
  @default_limit 120
  @default_window_ms 60_000

  def init(opts), do: opts

  def call(conn, opts) do
    if health_check?(conn), do: conn, else: do_rate_limit(conn, opts)
  end

  defp do_rate_limit(conn, opts) do
    limit = Keyword.get(opts, :limit, @default_limit)
    window_ms = Keyword.get(opts, :window_ms, @default_window_ms)
    key = rate_key(conn)

    case check_rate(key, limit, window_ms) do
      :ok ->
        conn

      :deny ->
        body = Jason.encode!(%{error: "Rate limit exceeded"})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(429, body)
        |> halt()
    end
  end

  defp health_check?(conn) do
    conn.method == "GET" and conn.request_path == "/mcp/health"
  end

  defp rate_key(conn) do
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()

    identity =
      case Plug.Conn.get_req_header(conn, "x-api-key") do
        [key | _] when is_binary(key) and key != "" ->
          key
          |> hash_key()
          |> then(&"key:#{&1}")

        _ ->
          "ip:#{ip}"
      end

    "#{identity}:#{conn.request_path}"
  end

  defp hash_key(key) do
    :crypto.hash(:sha256, key)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp check_rate(key, limit, window_ms) do
    ensure_table()
    now = System.system_time(:millisecond)
    bucket = div(now, window_ms)
    ets_key = {key, bucket}

    count = :ets.update_counter(@table, ets_key, 1, {ets_key, 0})

    if count > limit do
      :deny
    else
      :ok
    end
  end

  defp ensure_table do
    case :ets.info(@table) do
      :undefined ->
        :ets.new(@table, [
          :named_table,
          :protected,
          read_concurrency: true,
          write_concurrency: true
        ])

      _ ->
        :ok
    end
  end
end
