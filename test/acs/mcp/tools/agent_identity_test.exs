defmodule Acs.MCP.Tools.AgentIdentityTest do
  use Acs.DataCase, async: false

  alias Acs.MCP.Tools

  test "blank agent_id is coerced to OAuth auth identity" do
    assert {:ok, _result} =
             Tools.call_tool("get_present_status", %{
               "agent_id" => "",
               "_auth_agent_id" => "email|oauth-user",
               "_auth_role" => "member"
             })
  end

  test "mismatched agent_id still rejected when auth identity present" do
    assert {:error, reason} =
             Tools.call_tool("get_present_status", %{
               "agent_id" => "Eve",
               "_auth_agent_id" => "email|oauth-user",
               "_auth_role" => "member"
             })

    assert reason =~ "does not match authenticated identity"
  end
end
