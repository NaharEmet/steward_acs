defmodule AcsWeb.Plugs.LoginRateLimitTest do
  use ExUnit.Case, async: false

  alias AcsWeb.Plugs.LoginRateLimit

  test "limits repeated login attempts for the same identity" do
    username = "login-#{System.unique_integer([:positive])}"

    conn = login_conn(username) |> LoginRateLimit.call(limit: 2, window_ms: 60_000)
    refute conn.halted

    conn = login_conn(username) |> LoginRateLimit.call(limit: 2, window_ms: 60_000)
    refute conn.halted

    conn = login_conn(username) |> LoginRateLimit.call(limit: 2, window_ms: 60_000)
    assert conn.halted
    assert conn.status == 429
    assert Plug.Conn.get_resp_header(conn, "retry-after") == ["60"]
  end

  test "does not rate limit the login form GET" do
    conn = Plug.Test.conn(:get, "/users/log_in") |> LoginRateLimit.call(limit: 0)
    refute conn.halted
  end

  defp login_conn(username) do
    Plug.Test.conn(:post, "/users/log_in", %{
      "user" => %{"username" => username, "password" => "invalid"}
    })
  end
end
