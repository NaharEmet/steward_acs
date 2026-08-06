defmodule Acs.MCP.ToolRegistryTenantTest do
  use Acs.DataCase, async: false

  alias Acs.Artifacts.Ledger
  alias Acs.MCP.{ToolLoader, ToolRegistry}

  setup do
    shared =
      Path.join(System.tmp_dir!(), "tool_registry_shared_#{System.unique_integer([:positive])}")

    original_multi = Application.get_env(:steward_acs, :multi_tenant)
    original_org = Application.get_env(:steward_acs, :org_name)
    original_env = System.get_env("MCP_TOOLS_PATH")

    Application.put_env(:steward_acs, :multi_tenant, true)
    Application.put_env(:steward_acs, :org_name, "default")
    System.put_env("MCP_TOOLS_PATH", shared)
    File.mkdir_p!(shared)

    for slug <- ["org-a", "org-b"] do
      assert {:ok, _org} = Acs.Orgs.create(%{name: slug, slug: slug, subdomain: slug})
    end

    on_exit(fn ->
      restore_env(:multi_tenant, original_multi)
      restore_env(:org_name, original_org)

      if original_env,
        do: System.put_env("MCP_TOOLS_PATH", original_env),
        else: System.delete_env("MCP_TOOLS_PATH")

      Acs.Org.clear_request_org()
      File.rm_rf!(shared)
      ToolRegistry.refresh()
    end)

    %{shared: shared}
  end

  test "same tool name is isolated by tenant without provisioned vault directories" do
    for slug <- ["org-a", "org-b"] do
      refute File.dir?(Acs.Org.tools_dir(slug))
    end

    save_tool("org-a", "same", "Org A", ["collaborator"])
    save_tool("org-b", "same", "Org B", ["admin"])
    assert :ok = ToolRegistry.refresh()

    assert ToolRegistry.get_tool("same", "org-a")["description"] == "Org A"
    assert ToolRegistry.get_tool("same", "org-b")["description"] == "Org B"
    assert :ok = ToolRegistry.authorize_tool("same", "collaborator", [], "org-a")
    assert {:error, _} = ToolRegistry.authorize_tool("same", "collaborator", [], "org-b")
    refute Enum.any?(ToolRegistry.list_tools(nil, "org-a"), &(&1["description"] == "Org B"))
  end

  test "tenant authorization denial does not fall through to a shared definition", %{
    shared: shared
  } do
    write_shared_tool(shared, "shadowed", "Shared", ["collaborator"])
    save_tool("org-a", "shadowed", "Tenant", ["admin"])
    assert :ok = ToolRegistry.refresh()

    assert {:error, _} = ToolRegistry.authorize_tool("shadowed", "collaborator", [], "org-a")
    assert :ok = ToolRegistry.authorize_tool("shadowed", "collaborator", [], "org-b")
    assert ToolRegistry.get_tool("shadowed", "org-a")["description"] == "Tenant"
    assert ToolRegistry.get_tool("shadowed", "org-b")["description"] == "Shared"
  end

  test "tenant definitions reject ownership and internal handlers" do
    assert {:error, reason} =
             ToolLoader.validate_config(
               %{
                 "app" => "test",
                 "org" => "org-b",
                 "tools" => [endpoint_tool("spoof", "spoof", [])]
               },
               {:tenant_db, "org-a"}
             )

    assert reason =~ "ownership"

    assert {:error, reason} =
             ToolLoader.validate_config(
               %{
                 "app" => "test",
                 "tools" => [
                   %{
                     "name" => "handler",
                     "description" => "handler",
                     "handler" => "Acs.MCP.Tools"
                   }
                 ]
               },
               {:tenant_db, "org-a"}
             )

    assert reason =~ "Tenant tools must use endpoints"
  end

  test "tenant database tools cannot shadow reserved core tools" do
    save_tool("org-a", "help", "Reserved", ["admin"])
    assert {:error, reason} = ToolRegistry.refresh()
    assert reason =~ "reserved core tool"
  end

  defp save_tool(org, name, description, roles) do
    tool = endpoint_tool(name, description, roles)

    config = %{
      "app" => "test",
      "prefix" => false,
      "base_url" => "https://example.com",
      "tools" => [tool]
    }

    assert {:ok, _} =
             Ledger.save(
               :tool,
               "test/#{name}",
               %{
                 "app" => "test",
                 "name" => name,
                 "description" => description,
                 "definition" => config,
                 "active" => true
               },
               org: org,
               actor: %{type: "system", id: "test"},
               source: "system"
             )
  end

  defp endpoint_tool(name, description, roles) do
    %{
      "name" => name,
      "description" => description,
      "endpoint" => "/run",
      "method" => "POST",
      "roles" => roles
    }
  end

  defp write_shared_tool(dir, name, description, roles) do
    File.write!(Path.join(dir, "#{name}.yaml"), """
    app: test
    prefix: false
    base_url: https://example.com
    tools:
      - name: #{name}
        description: #{description}
        endpoint: /run
        method: POST
        roles: #{inspect(roles)}
    """)
  end

  defp restore_env(key, nil), do: Application.delete_env(:steward_acs, key)
  defp restore_env(key, value), do: Application.put_env(:steward_acs, key, value)
end
