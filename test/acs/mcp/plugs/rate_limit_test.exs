defmodule Acs.MCP.Plugs.RateLimitTest do
  use ExUnit.Case, async: false

  alias Acs.MCP.Plugs.RateLimit
  alias Acs.MCP.RateLimitStore

  test "keeps its ETS table owned by the supervised store after a restart" do
    owner = Process.whereis(RateLimitStore)
    assert is_pid(owner)
    ref = Process.monitor(owner)

    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}
    new_owner = await_restarted_store(owner)

    assert :ets.info(:acs_rate_limit, :owner) == new_owner
  end

  test "enforces a shared limit for concurrent requests" do
    api_key = "rate-limit-concurrency-#{System.unique_integer([:positive, :monotonic])}"
    limit = 10

    results =
      1..40
      |> Task.async_stream(
        fn _ -> rate_limit_request(api_key, limit: limit) end,
        max_concurrency: 40,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, conn} -> conn end)

    assert Enum.count(results, &is_nil(&1.status)) == limit
    assert Enum.count(results, &(&1.status == 429)) == 30
  end

  test "bypasses the health check" do
    conn =
      Plug.Test.conn(:get, "/mcp/health")
      |> Plug.Conn.put_req_header("x-api-key", "health-#{System.unique_integer([:positive])}")

    assert %{halted: false, status: nil} = RateLimit.call(conn, limit: 0)
  end

  defp rate_limit_request(api_key, opts) do
    Plug.Test.conn(:get, "/mcp/v1/messages")
    |> Plug.Conn.put_req_header("x-api-key", api_key)
    |> RateLimit.call(opts)
  end

  defp await_restarted_store(previous_owner, attempts \\ 50)

  defp await_restarted_store(_previous_owner, 0), do: flunk("rate limit store did not restart")

  defp await_restarted_store(previous_owner, attempts) do
    case Process.whereis(RateLimitStore) do
      owner when is_pid(owner) and owner != previous_owner ->
        owner

      _ ->
        Process.sleep(10)
        await_restarted_store(previous_owner, attempts - 1)
    end
  end
end
