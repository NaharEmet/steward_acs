defmodule Acs.MCP.Tools.MemoryHandlersTest do
  use ExUnit.Case, async: true

  alias Acs.MCP.Tools.MemoryHandlers

  describe "generate_guidance_packet/1" do
    test "rejects invalid mode values" do
      assert {:error, msg} =
               MemoryHandlers.generate_guidance_packet(%{
                 "scope_path" => "test/module",
                 "mode" => "invalid"
               })

      assert msg =~ "Invalid mode"
    end
  end
end
