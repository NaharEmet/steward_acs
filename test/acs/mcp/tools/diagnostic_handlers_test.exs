defmodule Acs.MCP.Tools.DiagnosticHandlersTest do
  use Acs.DataCase, async: false

  alias Acs.MCP.Tools.DiagnosticHandlers

  describe "acs_query/1 read-only enforcement" do
    test "allows SELECT queries" do
      assert {:ok, %{row_count: _}} =
               DiagnosticHandlers.acs_query(%{
                 "sql" => "SELECT 1 AS one",
                 "purpose" => "test"
               })
    end

    test "rejects INSERT" do
      assert {:error, msg} =
               DiagnosticHandlers.acs_query(%{
                 "sql" => "INSERT INTO acs_memories (id) VALUES ('x')",
                 "purpose" => "test"
               })

      assert msg =~ "SELECT" or msg =~ "not allowed"
    end

    test "rejects DELETE" do
      assert {:error, msg} =
               DiagnosticHandlers.acs_query(%{
                 "sql" => "DELETE FROM acs_memories",
                 "purpose" => "test"
               })

      assert msg =~ "SELECT" or msg =~ "not allowed"
    end

    test "rejects multiple statements" do
      assert {:error, msg} =
               DiagnosticHandlers.acs_query(%{
                 "sql" => "SELECT 1; DROP TABLE acs_memories",
                 "purpose" => "test"
               })

      assert msg =~ "Multiple SQL statements"
    end
  end
end
