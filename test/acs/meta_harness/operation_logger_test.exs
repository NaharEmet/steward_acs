defmodule Acs.MetaHarness.OperationLoggerTest do
  @moduledoc """
  Tests for the ACS Meta-Harness OperationLogger module.
  Tests public API - extract_result_info is tested through
  log_tool_result_async which delegates to it internally.
  """
  use ExUnit.Case, async: true

  alias Acs.MetaHarness.OperationLogger

  describe "log_async/8" do
    test "returns :ok with minimal arguments" do
      assert :ok = OperationLogger.log_async("ping", :success, nil)
    end

    test "returns :ok with all arguments" do
      assert :ok =
               OperationLogger.log_async(
                 "lock_file",
                 :success,
                 12,
                 nil,
                 nil,
                 "Alice",
                 "exec-123",
                 execution_chain_id: "chain-1",
                 sequence_order: 1,
                 attempt: 1,
                 tool_discovered: false,
                 error_burst: false,
                 params_hash: "abc123"
               )
    end

    test "returns :ok for failure status" do
      assert :ok = OperationLogger.log_async("create_work", :failure, 8, "timeout", "timed out", "Bob")
    end

    test "returns :ok for error status" do
      assert :ok = OperationLogger.log_async("lock_file", :error, nil, "db_error", "DB connection failed")
    end

    test "returns :ok with nil latency" do
      assert :ok = OperationLogger.log_async("ping", :success, nil, nil, nil, "agent-1")
    end
  end

  describe "log/8" do
    test "returns :ok" do
      assert :ok = OperationLogger.log("test_tool", :success, 10, nil, nil, "agent-1")
    end

    test "returns :ok for failure case" do
      assert :ok = OperationLogger.log("test_tool", :failure, 5, "err", "something broke", "agent-1", "exec-1")
    end
  end

  describe "log_tool_result_async/6" do
    test "handles {:ok, _} result" do
      assert :ok = OperationLogger.log_tool_result_async("test_tool", {:ok, %{result: "data"}}, 15, "agent-1", "exec-1")
    end

    test "handles :ok result" do
      assert :ok = OperationLogger.log_tool_result_async("test_tool", :ok, nil)
    end

    test "handles {:sleep, _, _} result" do
      assert :ok = OperationLogger.log_tool_result_async("test_tool", {:sleep, 1000, :timer}, 5)
    end

    test "handles {:error, binary} result" do
      assert :ok =
               OperationLogger.log_tool_result_async(
                 "test_tool",
                 {:error, "task_not_found: no such task"},
                 8,
                 "agent-1"
               )
    end

    test "handles {:error, map_with_reason} result" do
      assert :ok =
               OperationLogger.log_tool_result_async(
                 "test_tool",
                 {:error, %{reason: "timeout occurred"}},
                 3
               )
    end

    test "handles {:error, atom} result" do
      assert :ok = OperationLogger.log_tool_result_async("test_tool", {:error, :badarg}, nil)
    end

    test "handles unexpected result type" do
      assert :ok = OperationLogger.log_tool_result_async("test_tool", %{unexpected: "value"}, nil)
    end

    test "handles minimal arguments" do
      assert :ok = OperationLogger.log_tool_result_async("ping", :ok, nil)
    end
  end

  describe "buffer_size/0 and flush/0" do
    test "buffer_size returns non-negative integer" do
      size = OperationLogger.buffer_size()
      assert is_integer(size)
      assert size >= 0
    end

    test "flush returns :ok or :error" do
      result = OperationLogger.flush()
      assert result in [:ok, :error]
    end
  end
end
