defmodule Acs.RuntimeConfigTest do
  use ExUnit.Case, async: true

  alias Acs.Prompts

  describe "Prompts.load/3 for memory evaluate" do
    test "loads builtin memory evaluate prompt" do
      content = Prompts.load("memory", "evaluate", default: "fallback")
      assert is_binary(content)
      assert content != "fallback"
      assert String.contains?(content, "memory")
    end
  end
end
