defmodule Acs.MCP.ToolRegistryAuthorizationTest do
  use ExUnit.Case, async: false

  alias Acs.MCP.ToolRegistry

  test "permission-protected tools fail closed when credentials have no permissions" do
    name = "permission_test_#{System.unique_integer([:positive])}"

    assert :ok =
             ToolRegistry.register_tool(%{
               "name" => name,
               "description" => "authorization regression test",
               "roles" => ["collaborator"],
               "permissions" => ["mcp:sensitive"],
               "handler" => "Acs.MCP.Tools",
               "app" => "test",
               "category" => "test"
             })

    assert {:error, reason} = ToolRegistry.authorize_tool(name, "collaborator", nil)
    assert reason =~ "mcp:sensitive"

    assert {:error, _reason} = ToolRegistry.authorize_tool(name, "collaborator", [])
    assert :ok = ToolRegistry.authorize_tool(name, "collaborator", ["mcp:sensitive"])
  end
end
