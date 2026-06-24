defmodule Acs.Log.LogRepoTest do
  use Acs.DataCase, async: false

  alias Acs.Log.LogRepo

  describe "insert_raw/5" do
    test "inserts a log entry" do
      assert {:ok, entry} = LogRepo.insert_raw("info", "test-service", "test-component", "test message", %{key: "val"})
      assert entry.level == "info"
      assert entry.message == "test message"
      assert entry.service == "test-service"
    end

    test "accepts optional workflow_id and execution_id" do
      assert {:ok, entry} = LogRepo.insert_raw("error", "svc", "cmp", "err", %{}, workflow_id: "wf-1", execution_id: "exec-1")
      assert entry.workflow_id == "wf-1"
      assert entry.execution_id == "exec-1"
    end
  end

  describe "query/1" do
    test "returns inserted logs" do
      LogRepo.insert_raw("info", "svc", "cmp", "hello", %{})
      results = LogRepo.query(limit: 10)
      assert length(results) > 0
      assert Enum.any?(results, fn e -> e.message == "hello" end)
    end

    test "filters by level" do
      LogRepo.insert_raw("error", "svc", "cmp", "err msg", %{})
      LogRepo.insert_raw("info", "svc", "cmp", "info msg", %{})

      errors = LogRepo.query(level: "error", limit: 10)
      assert Enum.all?(errors, fn e -> e.level == "error" end)
    end

    test "filters by search" do
      LogRepo.insert_raw("info", "svc", "cmp", "unique_search_term_xyz", %{})
      results = LogRepo.query(search: "unique_search_term_xyz", limit: 10)
      assert length(results) >= 1
    end

    test "filters by cluster" do
      LogRepo.insert_raw("info", "svc", "cmp", "cluster-test", %{}, cluster: "test-cluster-a")
      LogRepo.insert_raw("info", "svc", "cmp", "cluster-other", %{}, cluster: "test-cluster-b")

      results = LogRepo.query(cluster: "test-cluster-a", limit: 10)
      assert Enum.all?(results, fn e -> e.cluster == "test-cluster-a" end)
    end
  end

  describe "count/1" do
    test "counts all logs" do
      LogRepo.insert_raw("info", "svc", "cmp", "count-test", %{})
      count = LogRepo.count()
      assert is_integer(count)
      assert count > 0
    end

    test "counts filtered logs" do
      LogRepo.insert_raw("error", "svc", "cmp", "count-error", %{})
      count = LogRepo.count(level: "error")
      assert is_integer(count)
      assert count > 0
    end
  end
end
