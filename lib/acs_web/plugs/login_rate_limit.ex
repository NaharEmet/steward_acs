defmodule AcsWeb.Plugs.LoginRateLimit do
  @moduledoc false

  import Plug.Conn

  alias Acs.MCP.RateLimitStore

  @limit 10
  @window_ms 60_000

  def init(opts), do: opts

  def call(%Plug.Conn{method: "POST"} = conn, opts) do
    limit = Keyword.get(opts, :limit, @limit)
    window_ms = Keyword.get(opts, :window_ms, @window_ms)

    ip_limit = Keyword.get(opts, :ip_limit, max(limit * 10, 100))

    result =
      with :ok <- RateLimitStore.check(ip_rate_key(conn), ip_limit, window_ms),
           :ok <- RateLimitStore.check(account_rate_key(conn), limit, window_ms) do
        :ok
      end

    case result do
      :ok ->
        conn

      :deny ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(div(window_ms, 1_000)))
        |> put_resp_content_type("text/plain")
        |> send_resp(429, "Too many login attempts. Try again later.")
        |> halt()
    end
  end

  def call(conn, _opts), do: conn

  defp ip_rate_key(conn) do
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()
    "dashboard-login:ip:#{ip}"
  end

  defp account_rate_key(conn) do
    username = get_in(conn.body_params, ["user", "username"]) || "unknown"
    canonical = username |> String.trim() |> String.downcase()
    digest = :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)
    "dashboard-login:account:#{digest}"
  end
end
