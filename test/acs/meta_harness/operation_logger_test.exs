defmodule Acs.MetaHarness.OperationLoggerTest do
  @moduledoc """
  Tests for the ACS Meta-Harness OperationLogger module.
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
      assert :ok =
               OperationLogger.log_async(
                 "create_work",
                 :failure,
                 8,
                 "timeout",
                 "timed out",
                 "Bob"
               )
    end

    test "returns :ok for error status" do
      assert :ok =
               OperationLogger.log_async(
                 "lock_file",
                 :error,
                 nil,
                 "db_error",
                 "DB connection failed"
               )
    end

    test "returns :ok with nil latency" do
      assert :ok = OperationLogger.log_async("ping", :success, nil, nil, nil, "agent-1")
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
