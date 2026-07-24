defmodule AcsWeb.Plugs.ResolveOrgTest do
  use AcsWeb.ConnCase, async: false

  alias AcsWeb.Plugs.ResolveOrg

  setup do
    original_env =
      Map.new([:account_host, :base_domain, :multi_tenant, :orgs_file], fn key ->
        {key, Application.fetch_env(:steward_acs, key)}
      end)

    orgs_file =
      Path.join(
        System.tmp_dir!(),
        "resolve_org_test_#{System.unique_integer([:positive])}.yaml"
      )

    File.write!(
      orgs_file,
      """
      orgs:
        yaml-tenant:
          name: YAML Tenant
          slug: yaml-tenant
          subdomain: yaml-tenant
          plan: free
      """
    )

    Application.put_env(:steward_acs, :account_host, "account.stewardacs.xyz")
    Application.put_env(:steward_acs, :base_domain, "stewardacs.xyz")
    Application.put_env(:steward_acs, :multi_tenant, true)
    Application.put_env(:steward_acs, :orgs_file, orgs_file)
    Acs.Org.clear_request_org()

    on_exit(fn ->
      Enum.each(original_env, fn
        {key, {:ok, value}} -> Application.put_env(:steward_acs, key, value)
        {key, :error} -> Application.delete_env(:steward_acs, key)
      end)

      Acs.Org.clear_request_org()
      File.rm(orgs_file)
    end)

    :ok
  end

  test "identifies the configured account host" do
    result =
      Plug.Test.conn(:get, "/")
      |> Map.put(:host, "account.stewardacs.xyz")
      |> ResolveOrg.call([])

    assert result.assigns.host_type == :account
    refute Map.has_key?(result.assigns, :current_org)
  end

  test "account host that is also an org subdomain keeps account_tenant scope" do
    Application.put_env(:steward_acs, :account_host, "yaml-tenant.stewardacs.xyz")

    result =
      Plug.Test.conn(:get, "/")
      |> Map.put(:host, "yaml-tenant.stewardacs.xyz")
      |> ResolveOrg.call([])

    assert result.assigns.host_type == :account_tenant
    assert result.assigns.current_org == "yaml-tenant"
    assert Acs.Org.current() == "yaml-tenant"
  end

  test "assigns the tenant for a known YAML organization host" do
    result =
      Plug.Test.conn(:get, "/")
      |> Map.put(:host, "yaml-tenant.stewardacs.xyz")
      |> ResolveOrg.call([])

    assert result.assigns.host_type == :tenant
    assert result.assigns.current_org == "yaml-tenant"
    assert Acs.Org.current() == "yaml-tenant"
  end

  test "returns not found for an unknown tenant host" do
    result =
      Plug.Test.conn(:get, "/")
      |> Map.put(:host, "unknown.stewardacs.xyz")
      |> ResolveOrg.call([])

    assert %Plug.Conn{halted: true, status: 404, resp_body: "unknown org"} = result
    assert result.assigns.host_type == :unknown
  end

  test "allows /mcp/health on localhost without a tenant host" do
    result =
      Plug.Test.conn(:get, "/mcp/health")
      |> Map.put(:host, "localhost")
      |> ResolveOrg.call([])

    refute result.halted
    assert result.assigns.host_type == :account_tenant
  end
end
