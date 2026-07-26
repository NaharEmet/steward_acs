defmodule Acs.MCP.HealthCheckCacheTest do
  use ExUnit.Case, async: false

  alias Acs.MCP.HealthCheckCache

  setup do
    previous = Application.get_env(:steward_acs, HealthCheckCache)
    HealthCheckCache.clear()

    on_exit(fn ->
      HealthCheckCache.clear()

      if previous do
        Application.put_env(:steward_acs, HealthCheckCache, previous)
      else
        Application.delete_env(:steward_acs, HealthCheckCache)
      end
    end)

    :ok
  end

  test "caches health by URL" do
    assert :miss = HealthCheckCache.get("https://app.example")
    assert :ok = HealthCheckCache.put("https://app.example", :up)
    assert {:ok, :up} = HealthCheckCache.get("https://app.example")
    assert :miss = HealthCheckCache.get("https://other.example")
  end

  test "expires cached health after the configured TTL" do
    Application.put_env(:steward_acs, HealthCheckCache, ttl_ms: 1)
    HealthCheckCache.put("https://app.example", :down)
    Process.sleep(5)

    assert :miss = HealthCheckCache.get("https://app.example")
  end
end
