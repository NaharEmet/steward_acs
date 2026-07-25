defmodule Acs.MCP.ToolRegistryTenantTest do
  use Acs.DataCase, async: false

  alias Acs.MCP.ToolRegistry

  setup do
    vault =
      Path.join(System.tmp_dir!(), "tool_registry_tenants_#{System.unique_integer([:positive])}")

    shared = Path.join(vault, "shared")
    original_vault = Application.get_env(:steward_acs, :obsidian_vault_path)
    original_multi = Application.get_env(:steward_acs, :multi_tenant)
    original_org = Application.get_env(:steward_acs, :org_name)
    original_env = System.get_env("MCP_TOOLS_PATH")

    Application.put_env(:steward_acs, :obsidian_vault_path, vault)
    Application.put_env(:steward_acs, :multi_tenant, true)
    Application.put_env(:steward_acs, :org_name, "default")
    System.put_env("MCP_TOOLS_PATH", shared)
    File.mkdir_p!(shared)

    for slug <- ["org-a", "org-b"] do
      assert {:ok, _org} =
               Acs.Orgs.create(%{name: slug, slug: slug, subdomain: slug})
    end

    on_exit(fn ->
      restore_env(:obsidian_vault_path, original_vault)
      restore_env(:multi_tenant, original_multi)
      restore_env(:org_name, original_org)

      if original_env,
        do: System.put_env("MCP_TOOLS_PATH", original_env),
        else: System.delete_env("MCP_TOOLS_PATH")

      Acs.Org.clear_request_org()
      File.rm_rf!(vault)
      ToolRegistry.refresh()
    end)

    %{vault: vault, shared: shared}
  end

  test "same tool name is isolated by tenant and all provisioned directories exist" do
    for slug <- ["org-a", "org-b"] do
      for dir <- [
            Acs.Org.memory_dir(slug),
            Acs.Org.skills_dir(slug),
            Acs.Org.specs_dir(slug),
            Acs.Org.prompts_dir(slug),
            Acs.Org.tools_dir(slug)
          ] do
        assert File.dir?(dir)
      end
    end

    write_tool(Acs.Org.tools_dir("org-a"), "same", "Org A", ["collaborator"])
    write_tool(Acs.Org.tools_dir("org-b"), "same", "Org B", ["admin"])
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
    write_tool(shared, "shadowed", "Shared", ["collaborator"])
    write_tool(Acs.Org.tools_dir("org-a"), "shadowed", "Tenant", ["admin"])
    assert :ok = ToolRegistry.refresh()

    assert {:error, _} =
             ToolRegistry.authorize_tool("shadowed", "collaborator", [], "org-a")

    assert :ok = ToolRegistry.authorize_tool("shadowed", "collaborator", [], "org-b")
    assert ToolRegistry.get_tool("shadowed", "org-a")["description"] == "Tenant"
    assert ToolRegistry.get_tool("shadowed", "org-b")["description"] == "Shared"
  end

  test "malformed refresh retains last-known-good tenant snapshot" do
    dir = Acs.Org.tools_dir("org-a")
    write_tool(dir, "stable", "Stable", ["collaborator"])
    assert :ok = ToolRegistry.refresh()
    assert ToolRegistry.get_tool("stable", "org-a")

    File.write!(Path.join(dir, "broken.yaml"), "tools: [")
    write_tool(Acs.Org.tools_dir("org-b"), "fresh", "Fresh", ["collaborator"])

    assert {:error, _} = ToolRegistry.refresh()
    assert ToolRegistry.get_tool("stable", "org-a")["description"] == "Stable"
    assert ToolRegistry.get_tool("fresh", "org-b")["description"] == "Fresh"
  end

  test "tenant YAML cannot spoof ownership, define handlers, or shadow core tools" do
    dir = Acs.Org.tools_dir("org-a")

    File.write!(Path.join(dir, "spoof.yaml"), """
    app: test
    org: org-b
    tools:
      - name: spoof
        description: spoof
        endpoint: /run
        method: POST
    """)

    assert {:error, reason} = ToolRegistry.refresh()
    assert reason =~ "ownership"
    File.rm!(Path.join(dir, "spoof.yaml"))

    File.write!(Path.join(dir, "handler.yaml"), """
    app: test
    tools:
      - name: handler
        description: handler
        handler: Acs.MCP.Tools
    """)

    assert {:error, reason} = ToolRegistry.refresh()
    assert reason =~ "Tenant tools must use endpoints"
    File.rm!(Path.join(dir, "handler.yaml"))

    write_tool(dir, "help", "Reserved", ["admin"])
    assert {:error, reason} = ToolRegistry.refresh()
    assert reason =~ "reserved core tool"
  end

  defp write_tool(dir, name, description, roles) do
    File.mkdir_p!(dir)

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
