defmodule Acs.Observability.VmMetricsTest do
  use ExUnit.Case, async: false

  alias Acs.Observability.VmMetrics

  test "sample emits memory and scheduler fields" do
    {first, prev} = VmMetrics.sample(nil)
    assert first["message"] == "vm.metrics"
    assert first["event"] == "vm.metrics"
    assert is_integer(first["memory_total_bytes"]) and first["memory_total_bytes"] > 0
    assert is_integer(first["process_count"]) and first["process_count"] > 0
    assert first["scheduler_utilization"] == 0.0
    assert is_map(prev)
    assert Map.has_key?(prev, :schedulers)

    # Host fields are best-effort Linux; assert shape when present.
    if Map.has_key?(first, "host_memory_total_bytes") do
      assert first["host_memory_total_bytes"] > 0
    end

    Process.sleep(10)
    {second, _} = VmMetrics.sample(prev)
    assert second["scheduler_utilization"] >= 0.0
    assert second["scheduler_utilization"] <= 1.0

    if Map.has_key?(second, "cgroup_cpu_utilization") do
      assert second["cgroup_cpu_utilization"] >= 0.0
      assert second["cgroup_cpu_utilization"] <= 1.0
    end
  end

  test "sample accepts legacy scheduler-list prev" do
    {_, schedulers} = VmMetrics.sample(nil)
    {event, _} = VmMetrics.sample(schedulers.schedulers)
    assert event["message"] == "vm.metrics"
  end

  test "poller enqueues metrics via exporter callback" do
    test_pid = self()
    enqueue = fn event -> send(test_pid, {:vm_metric, event}) end

    {:ok, pid} =
      start_supervised(
        {VmMetrics, name: :"vm_metrics_test_#{System.unique_integer([:positive])}", interval_ms: 20, exporter: enqueue}
      )

    assert_receive {:vm_metric, event}, 500
    assert event["message"] == "vm.metrics"
    assert is_integer(event["memory_total_bytes"])
    assert Process.alive?(pid)
  end
end
