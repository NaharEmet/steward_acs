defmodule Acs.MetaHarnessTest do
  use ExUnit.Case, async: false

  alias Acs.MetaHarness

  setup do
    prev = System.get_env("META_HARNESS_ENABLED")
    on_exit(fn -> restore_env(prev) end)
    :ok
  end

  test "enabled?/0 defaults to true when env unset" do
    System.delete_env("META_HARNESS_ENABLED")
    assert MetaHarness.enabled?()
  end

  test "enabled?/0 respects explicit false" do
    System.put_env("META_HARNESS_ENABLED", "false")
    refute MetaHarness.enabled?()
  end

  test "enabled?/0 respects explicit true" do
    System.put_env("META_HARNESS_ENABLED", "true")
    assert MetaHarness.enabled?()
  end

  defp restore_env(nil), do: System.delete_env("META_HARNESS_ENABLED")
  defp restore_env(val), do: System.put_env("META_HARNESS_ENABLED", val)
end
