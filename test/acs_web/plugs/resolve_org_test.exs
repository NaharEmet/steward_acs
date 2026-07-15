defmodule AcsWeb.Plugs.ResolveOrgTest do
  use ExUnit.Case, async: false

  alias AcsWeb.Plugs.ResolveOrg
  alias Acs.Orgs

  setup do
    original_mt = Application.get_env(:steward_acs, :multi_tenant)
    original_bd = Application.get_env(:steward_acs, :base_domain)
    original_of = Application.get_env(:steward_acs, :orgs_file)

    Application.put_env(:steward_acs, :multi_tenant, true)
    Application.put_env(:steward_acs, :base_domain, "stewardacs.xyz")

    tmp = Path.join(System.tmp_dir!(), "resolve_org_test_#{System.unique_integer([:positive])}.yaml")
    File.write!(tmp, "orgs:\n  default:\n    name: Default\n    slug: default\n    subdomain: default\n    plan: free\n")
    Application.put_env(:steward_acs, :orgs_file, tmp)

    {:ok, _} = Orgs.create(%{name: "Acme Corp", slug: "acme", subdomain: "acme"})

    on_exit(fn ->
      if is_nil(original_mt), do: Application.delete_env(:steward_acs, :multi_tenant), else: Application.put_env(:steward_acs, :multi_tenant, original_mt)
      if is_nil(original_bd), do: Application.delete_env(:steward_acs, :base_domain), else: Application.put_env(:steward_acs, :base_domain, original_bd)
      if is_nil(original_of), do: Application.delete_env(:steward_acs, :orgs_file), else: Application.put_env(:steward_acs, :orgs_file, original_of)
      Acs.Org.clear_request_org()
      File.rm(tmp)
    end)

    :ok
  end

  test "resolves known org from subdomain" do
    conn =
      Plug.Test.conn(:get, "/")
      |> Map.put(:host, "acme.stewardacs.xyz")

    result = ResolveOrg.call(conn, [])
    assert result.assigns.current_org == "acme"
    assert Acs.Org.current() == "acme"
  end

  test "returns 404 for unknown org" do
    conn =
      Plug.Test.conn(:get, "/")
      |> Map.put(:host, "unknown.stewardacs.xyz")

    assert %Plug.Conn{status: 404, halted: true} = ResolveOrg.call(conn, [])
  end

  test "apex resolves to default org" do
    conn =
      Plug.Test.conn(:get, "/")
      |> Map.put(:host, "stewardacs.xyz")

    result = ResolveOrg.call(conn, [])
    assert result.assigns.current_org == "default"
  end
end
