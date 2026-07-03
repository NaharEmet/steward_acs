defmodule Acs.MCP.ProtocolTest do
  use ExUnit.Case, async: true

  alias Acs.MCP.Protocol

  describe "handle_message/7 auth requirements" do
    test "tools/call without agent role returns unauthorized" do
      msg = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "help", "arguments" => %{}}
      }

      assert {:ok, %{"error" => %{"code" => -32_001, "message" => "Unauthorized"}}} =
               Protocol.handle_message(msg, nil)
    end

    test "tools/list without agent role returns unauthorized" do
      msg = %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/list",
        "params" => %{}
      }

      assert {:ok, %{"error" => %{"code" => -32_001, "message" => "Unauthorized"}}} =
               Protocol.handle_message(msg, nil)
    end

    test "initialize succeeds without agent role" do
      msg = %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "initialize",
        "params" => %{}
      }

      assert {:ok, %{"result" => %{"protocolVersion" => _}}} = Protocol.handle_message(msg, nil)
    end
  end
end
