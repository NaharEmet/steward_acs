defmodule Acs.MCP.Tools.DiagnosticHandlersTest do
  use Acs.DataCase, async: false

  alias Acs.MCP.Tools.DiagnosticHandlers
  alias Acs.MCP.Tools.AppExtension.Default, as: AppExtensionDefault
  alias Acs.Memory.Schema
  alias Acs.Repo

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

  describe "config_lookup/1" do
    test "returns merged project + global opencode config for all" do
      assert {:ok, config} = DiagnosticHandlers.config_lookup(%{"path" => "all"})

      assert is_map(config)
      assert Map.has_key?(config, "plugin")
      assert Map.has_key?(config, "mcp")
    end

    test "returns error for unknown path" do
      assert {:ok, %{error: msg}} = DiagnosticHandlers.config_lookup(%{"path" => "bogus"})
      assert msg =~ "Unknown config path"
    end

    test "redacts secret keys in config" do
      assert {:ok, config} = DiagnosticHandlers.config_lookup(%{"path" => "all"})

      assert Jason.encode!(config) =~ "***redacted***"
    end
  end

  describe "memory_health_check/1 with default extension" do
    test "returns health, flow, and dlq summary" do
      Repo.insert!(%Schema{
        org: Acs.Org.current(),
        title: "ponytail audit test memory",
        status: "proposed",
        content: "ponytail audit test memory",
        kind: "learning",
        scope_path: "test/diagnostic_handlers"
      })

      assert {:ok, result} = DiagnosticHandlers.memory_health_check(%{})

      assert %{
               health: %{level: level},
               flow: %{},
               dlq: %{summary: dlq_summary}
             } = result

      assert level in [:healthy, :warning, :critical, :error]
      assert is_map(dlq_summary)
    end
  end

  describe "Acs.MCP.Tools.AppExtension.Default" do
    test "fetch_llm_config/0 returns provider key map" do
      config = AppExtensionDefault.fetch_llm_config()

      assert is_map(config)
      assert Map.has_key?(config, :minimax_key)
      assert Map.has_key?(config, :nim_key)
      assert Map.has_key?(config, :mimo_key)
      assert Map.has_key?(config, :openai_key)
    end

    test "fetch_dlq_entries/0 returns a list" do
      assert is_list(AppExtensionDefault.fetch_dlq_entries())
    end
  end
end
