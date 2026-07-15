defmodule Acs.MCP.ProtocolTest do
  use Acs.DataCase, async: false

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

    test "ordinary agents cannot override their organization for analysis" do
      msg = %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "tools/call",
        "params" => %{
          "name" => "create_work",
          "arguments" => %{
            "_analysis_org_id" => "org-b",
            "agent_id" => "agent-a",
            "title" => "Must remain in org A"
          }
        }
      }

      assert {:ok, %{"result" => %{"content" => [%{"text" => text}]}}} =
               Protocol.handle_message(msg, "collaborator", "org-a", [], nil, nil, "agent-a")

      assert %{"task_id" => task_id} = Jason.decode!(text)
      assert Acs.Org.with_current("org-a", fn -> Acs.get_task(task_id) end)
      refute Acs.Org.with_current("org-b", fn -> Acs.get_task(task_id) end)
    end

    test "developer analysis permission can target another organization" do
      msg = %{
        "jsonrpc" => "2.0",
        "id" => 4,
        "method" => "tools/call",
        "params" => %{
          "name" => "create_work",
          "arguments" => %{
            "_analysis_org_id" => "org-b",
            "agent_id" => "developer",
            "title" => "Cross-org analysis task"
          }
        }
      }

      permissions = ["mcp:cross_org_analysis"]

      assert {:ok, %{"result" => %{"content" => [%{"text" => text}]}}} =
               Protocol.handle_message(
                 msg,
                 "admin",
                 "org-a",
                 permissions,
                 nil,
                 nil,
                 "developer"
               )

      assert %{"task_id" => task_id} = Jason.decode!(text)
      assert Acs.Org.with_current("org-b", fn -> Acs.get_task(task_id) end)
      refute Acs.Org.with_current("org-a", fn -> Acs.get_task(task_id) end)
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
