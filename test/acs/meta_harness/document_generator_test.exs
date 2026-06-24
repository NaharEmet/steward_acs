defmodule Acs.MetaHarness.DocumentGeneratorTest do
  @moduledoc """
  Tests for the ACS Meta-Harness DocumentGenerator module.
  Tests through public API since formatting helpers are private.
  """
  use ExUnit.Case, async: true

  alias Acs.MetaHarness.DocumentGenerator

  describe "generate/1" do
    test "returns a string" do
      result = DocumentGenerator.generate(timeframe: :last_24_hours)
      assert is_binary(result)
    end

    test "contains expected section headers in output" do
      result = DocumentGenerator.generate(timeframe: :last_24_hours)

      assert result =~ "ACS Meta-Harness Report"
      assert result =~ "## Summary"
      assert result =~ "## Tool Reliability"
      assert result =~ "## Latency Analysis"
      assert result =~ "## Error Clusters"
      assert result =~ "## Agent Behavior"
      assert result =~ "## Recommendations"
    end

    test "shows no data for empty results" do
      result = DocumentGenerator.generate(timeframe: :last_24_hours)

      assert result =~ "_No data available_"
      assert result =~ "0.0%"
      assert result =~ "Tools Analyzed: 0"
    end

    test "shows no error clusters" do
      result = DocumentGenerator.generate(timeframe: :last_24_hours)

      assert result =~ "_No error clusters detected_"
    end
  end

  describe "generate_and_write/2" do
    test "writes report to file" do
      path = "/tmp/acs_meta_harness_test_report.md"

      result = DocumentGenerator.generate_and_write([timeframe: :last_24_hours], path)

      assert result == :ok
      content = File.read!(path)
      assert content =~ "ACS Meta-Harness Report"
      File.rm!(path)
    end
  end
end
