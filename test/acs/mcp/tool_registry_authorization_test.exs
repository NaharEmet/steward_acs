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
               "endpoint" => "/test",
               "base_url" => "https://example.com",
               "method" => "POST",
               "app" => "test",
               "category" => "test"
             })

    assert {:error, reason} = ToolRegistry.authorize_tool(name, "collaborator", nil)
    assert reason =~ "mcp:sensitive"

    assert {:error, _reason} = ToolRegistry.authorize_tool(name, "collaborator", [])
    assert :ok = ToolRegistry.authorize_tool(name, "collaborator", ["mcp:sensitive"])
  end

  test "runtime registration rejects tenant internal handlers" do
    name = "handler_bypass_#{System.unique_integer([:positive])}"

    assert {:error, reason} =
             ToolRegistry.register_tool(%{
               "name" => name,
               "description" => "must be rejected",
               "handler" => "Acs.MCP.Tools",
               "roles" => ["admin"]
             })

    assert reason =~ "cannot define internal handlers"
  end
end
