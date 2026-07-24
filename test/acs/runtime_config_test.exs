defmodule Acs.RuntimeConfigTest do
  use ExUnit.Case, async: true

  alias Acs.Prompts

  describe "Axiom observability gate" do
    test "is disabled without a production token and configures no exporter headers" do
      refute Application.get_env(:steward_acs, :axiom)[:enabled]
      assert Application.get_env(:opentelemetry, :traces_exporter) == :none
      assert Application.get_env(:opentelemetry_exporter, :otlp_traces_headers) == nil
      assert Application.get_env(:opentelemetry_exporter, :otlp_headers) == nil
    end
  end

  describe "Prompts.load/3 for memory evaluate" do
    test "loads builtin memory evaluate prompt" do
      content = Prompts.load("memory", "evaluate", default: "fallback")
      assert is_binary(content)
      assert content != "fallback"
      assert String.contains?(content, "memory")
    end
  end
end
