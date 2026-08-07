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

    test "cross-org analysis permission cannot target mutating tools" do
      msg = %{
        "jsonrpc" => "2.0",
        "id" => 4,
        "method" => "tools/call",
        "params" => %{
          "name" => "create_work",
          "arguments" => %{
            "_analysis_org_id" => "org-b",
            "agent_id" => "developer",
            "title" => "Cross-org mutation must be denied"
          }
        }
      }

      permissions = ["mcp:cross_org_analysis"]

      assert {:ok,
              %{
                "result" => %{
                  "isError" => true,
                  "content" => [%{"text" => text}]
                }
              }} =
               Protocol.handle_message(
                 msg,
                 "admin",
                 "org-a",
                 permissions,
                 nil,
                 nil,
                 "developer"
               )

      assert text =~ "only permitted for read-only tools"
      assert Acs.Org.with_current("org-a", fn -> Acs.Acs.list_tasks() end) == []
      assert Acs.Org.with_current("org-b", fn -> Acs.Acs.list_tasks() end) == []
    end

    test "initialize succeeds without agent role" do
      msg = %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "initialize",
        "params" => %{}
      }

      assert {:ok, %{"result" => %{"protocolVersion" => _, "serverInfo" => info}}} =
               Protocol.handle_message(msg, nil)

      assert info["name"] == "Acs MCP Server"
      assert [%{"src" => src, "mimeType" => "image/png"} | _] = info["icons"]

      assert String.starts_with?(src, "http") or
               String.starts_with?(src, "data:image/png;base64,")
    end

    test "chat initialize instructions include authenticated display name" do
      msg = %{
        "jsonrpc" => "2.0",
        "id" => 5,
        "method" => "initialize",
        "params" => %{
          "clientInfo" => %{"name" => "claude.ai", "version" => "1"}
        }
      }

      assert {:ok, %{"result" => %{"instructions" => instructions}}} =
               Protocol.handle_message(
                 msg,
                 "collaborator",
                 "acme",
                 ["mcp:tools"],
                 nil,
                 nil,
                 "Nahar"
               )

      assert instructions =~ ~s(Connected ACS user: "Nahar")
      assert instructions =~ "never invent a nickname"
      assert instructions =~ "org or process knowledge"
      assert instructions =~ "steward_write"
      assert instructions =~ "never tool_search"
      refute instructions =~ "steward_ask(action:\"search\", content_query:)"
    end

    test "chat lists only consolidated tools and accepts a hidden legacy alias" do
      initialize = %{
        "jsonrpc" => "2.0",
        "id" => 20,
        "method" => "initialize",
        "params" => %{"clientInfo" => %{"name" => "claude.ai", "version" => "1"}}
      }

      assert {:ok, %{"result" => _}} =
               Protocol.handle_message(
                 initialize,
                 "collaborator",
                 "acme",
                 [],
                 nil,
                 nil,
                 "Alias User"
               )

      list = %{"jsonrpc" => "2.0", "id" => 21, "method" => "tools/list", "params" => %{}}

      assert {:ok, %{"result" => %{"tools" => tools}}} =
               Protocol.handle_message(list, "collaborator", "acme", [], nil, nil, "Alias User")

      assert Enum.map(tools, & &1["name"]) == ~w(steward_ask steward_write steward_work)
      assert Enum.all?(tools, &(&1["_meta"]["anthropic/alwaysLoad"] == true))

      legacy_call = %{
        "jsonrpc" => "2.0",
        "id" => 22,
        "method" => "tools/call",
        "params" => %{"name" => "get_started", "arguments" => %{}}
      }

      assert {:ok, %{"result" => %{"content" => [%{"text" => text}]}}} =
               Protocol.handle_message(
                 legacy_call,
                 "collaborator",
                 "acme",
                 [],
                 nil,
                 nil,
                 "Alias User"
               )

      assert Jason.decode!(text)["connected_user"] == "Alias User"
    end

    test "notifications/initialized has no JSON-RPC response body" do
      msg = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized",
        "params" => %{}
      }

      assert {:ok, nil} = Protocol.handle_message(msg, nil)
    end
  end

  describe "local mode coding identity (single-tenant admin self-identifies)" do
    test "instructions and get_started expose no default agent identity" do
      initialize = %{
        "jsonrpc" => "2.0",
        "id" => 30,
        "method" => "initialize",
        "params" => %{"clientInfo" => %{"name" => "cursor", "version" => "1"}}
      }

      assert {:ok, %{"result" => %{"instructions" => instructions}}} =
               Protocol.handle_message(initialize, "admin", "acme", [], nil, nil, "Nahar")

      assert instructions =~ "no default agent identity"
      assert instructions =~ "get_present_status(agent_id: your_name)"

      call = %{
        "jsonrpc" => "2.0",
        "id" => 31,
        "method" => "tools/call",
        "params" => %{"name" => "get_started", "arguments" => %{}}
      }

      assert {:ok, %{"result" => %{"content" => [%{"text" => text}]}}} =
               Protocol.handle_message(call, "admin", "acme", [], nil, nil, "Nahar")

      decoded = Jason.decode!(text)
      assert decoded["connected_user"] == nil
      assert decoded["authenticated_as"] == nil
      assert decoded["your_agent_id"] == nil
      assert decoded["agent_identity"] =~ "self-identify"
      assert decoded["get_started"] =~ "your_name"
    end

    test "local admin coding agent can create_work under its own agent_id" do
      initialize = %{
        "jsonrpc" => "2.0",
        "id" => 32,
        "method" => "initialize",
        "params" => %{"clientInfo" => %{"name" => "cursor", "version" => "1"}}
      }

      assert {:ok, %{"result" => _}} =
               Protocol.handle_message(initialize, "admin", "acme", [], nil, nil, "Nahar")

      call = %{
        "jsonrpc" => "2.0",
        "id" => 33,
        "method" => "tools/call",
        "params" => %{
          "name" => "create_work",
          "arguments" => %{"agent_id" => "opencode", "title" => "Local self-identified task"}
        }
      }

      assert {:ok, %{"result" => %{"content" => [%{"text" => text}]}}} =
               Protocol.handle_message(call, "admin", "acme", [], nil, nil, "Nahar")

      assert %{"task_id" => task_id} = Jason.decode!(text)
      task = Acs.Org.with_current("acme", fn -> Acs.get_task(task_id) end)
      assert task.created_by_agent == "opencode"
    end
  end
end
