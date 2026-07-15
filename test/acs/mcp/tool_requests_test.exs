defmodule Acs.MCP.ToolRequestsTest do
  use Acs.DataCase, async: false

  alias Acs.MCP.ToolRequests

  setup do
    Acs.Org.put_request_org("org-a")
    on_exit(fn -> Acs.Org.clear_request_org() end)
    :ok
  end

  test "list_requests only returns requests for current org" do
    {:ok, _} =
      ToolRequests.create_request("agent-a", %{"name" => "tool_a", "description" => "a"}, "org-a")

    {:ok, _} =
      ToolRequests.create_request("agent-b", %{"name" => "tool_b", "description" => "b"}, "org-b")

    assert length(ToolRequests.list_requests(nil, "org-a")) == 1
    assert length(ToolRequests.list_requests(nil, "org-b")) == 1
  end

  test "get_request rejects cross-org access" do
    {:ok, req} =
      ToolRequests.create_request("agent-a", %{"name" => "tool_a", "description" => "a"}, "org-a")

    assert ToolRequests.get_request(req.id, "org-a")
    assert is_nil(ToolRequests.get_request(req.id, "org-b"))
  end
end
