defmodule Acs.MetaHarness.GeneratorTest do
  @moduledoc """
  Tests for the ACS Meta-Harness Generator module.
  Tests through public API since formatting helpers are private.
  """
  use ExUnit.Case, async: true

  alias Acs.MetaHarness.Generator

  describe "generate/0" do
    test "returns a map" do
      result = Generator.generate()

      assert is_map(result)
    end

    test "result has report, plan, and optionally error key" do
      result = Generator.generate()

      assert Map.has_key?(result, :report)
      assert Map.has_key?(result, :plan)
    end

    test "handles DB unavailability gracefully" do
      result = Generator.generate()

      # Either succeeds with file paths, or returns error map
      if result.report == "error" do
        assert Map.has_key?(result, :error)
        assert is_binary(result.error)
      else
        assert is_binary(result.report)
        assert is_binary(result.plan)
      end
    end
  end
end
