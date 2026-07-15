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

    tmp =
      Path.join(System.tmp_dir!(), "resolve_org_test_#{System.unique_integer([:positive])}.yaml")

    File.write!(
      tmp,
      "orgs:\n  default:\n    name: Default\n    slug: default\n    subdomain: default\n    plan: free\n"
    )

    Application.put_env(:steward_acs, :orgs_file, tmp)

    {:ok, _} = Orgs.create(%{name: "Acme Corp", slug: "acme", subdomain: "acme"})

    on_exit(fn ->
      restore_env(:multi_tenant, original_mt)
      restore_env(:base_domain, original_bd)
      restore_env(:orgs_file, original_of)
      Acs.Org.clear_request_org()
      File.rm(tmp)
    end)

    :ok
  end

  test "known org subdomain becomes a hint without setting current org" do
    :ok = Acs.Org.put_current("stale-org")

    result =
      Plug.Test.conn(:get, "/")
      |> Map.put(:host, "acme.stewardacs.xyz")
      |> ResolveOrg.call([])

    assert result.assigns.org_hint == "acme"
    refute Map.has_key?(result.assigns, :current_org)
    assert Acs.Org.current() == Acs.Org.configured()
  end

  test "unknown org host remains an unauthenticated hint" do
    result =
      Plug.Test.conn(:get, "/")
      |> Map.put(:host, "unknown.stewardacs.xyz")
      |> ResolveOrg.call([])

    refute result.halted
    assert result.assigns.org_hint == "unknown"
    refute Map.has_key?(result.assigns, :current_org)
  end

  test "apex is neutral and has no org hint" do
    result =
      Plug.Test.conn(:get, "/")
      |> Map.put(:host, "stewardacs.xyz")
      |> ResolveOrg.call([])

    refute Map.has_key?(result.assigns, :org_hint)
    refute Map.has_key?(result.assigns, :current_org)
  end

  defp restore_env(key, nil), do: Application.delete_env(:steward_acs, key)
  defp restore_env(key, value), do: Application.put_env(:steward_acs, key, value)
end
