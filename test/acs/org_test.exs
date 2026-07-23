defmodule Acs.OrgTest do
  use Acs.DataCase, async: false

  alias Acs.Org

  setup do
    originals =
      Map.new(
        [:base_domain, :multi_tenant, :obsidian_vault_path, :org_name, :orgs_file],
        fn key ->
          {key, Application.fetch_env(:steward_acs, key)}
        end
      )

    Application.put_env(:steward_acs, :base_domain, "stewardacs.xyz")

    on_exit(fn ->
      Enum.each(originals, fn
        {key, {:ok, value}} -> Application.put_env(:steward_acs, key, value)
        {key, :error} -> Application.delete_env(:steward_acs, key)
      end)

      Org.clear_request_org()
    end)

    :ok
  end

  describe "extract_subdomain/1" do
    test "apex host returns nil" do
      assert Org.extract_subdomain("stewardacs.xyz") == nil
    end

    test "www returns nil" do
      assert Org.extract_subdomain("www.stewardacs.xyz") == nil
    end

    test "org subdomain" do
      assert Org.extract_subdomain("acme.stewardacs.xyz") == "acme"
    end

    test "org obsidian subdomain" do
      assert Org.extract_subdomain("acme.obsidian.stewardacs.xyz") == "acme"
    end

    test "prod subdomain" do
      assert Org.extract_subdomain("prod.stewardacs.xyz") == "prod"
    end
  end

  describe "put_request_org/1 and current/0" do
    test "request org overrides config" do
      orig = Application.get_env(:steward_acs, :org_name)
      Application.put_env(:steward_acs, :org_name, "config-org")

      on_exit(fn ->
        if is_nil(orig),
          do: Application.delete_env(:steward_acs, :org_name),
          else: Application.put_env(:steward_acs, :org_name, orig)
      end)

      Org.put_request_org("request-org")
      assert Org.current() == "request-org"
    end
  end

  describe "memory_dir/1" do
    test "single-tenant mode keeps the legacy vault path and IDs" do
      Application.put_env(:steward_acs, :multi_tenant, false)
      Application.put_env(:steward_acs, :obsidian_vault_path, "/vaults")

      on_exit(fn ->
        Application.delete_env(:steward_acs, :multi_tenant)
        Application.delete_env(:steward_acs, :obsidian_vault_path)
      end)

      assert Org.memory_dir("any-org") == "/vaults/private/memories"
      assert Org.memory_index_id("memory-1", "any-org") == "memory-1"
    end

    test "keeps the configured org on the legacy path and partitions additional orgs" do
      Application.put_env(:steward_acs, :multi_tenant, true)
      Application.put_env(:steward_acs, :obsidian_vault_path, "/vaults")
      Application.put_env(:steward_acs, :org_name, "prod")

      on_exit(fn ->
        Application.delete_env(:steward_acs, :multi_tenant)
        Application.delete_env(:steward_acs, :obsidian_vault_path)
        Application.delete_env(:steward_acs, :org_name)
      end)

      assert Org.memory_dir("prod") == "/vaults/private/memories"
      assert Org.memory_dir("acme") == "/vaults/orgs/acme/private/memories"
      assert Org.org_from_vault_path("/vaults/private/memories/a.yaml") == "prod"
      assert Org.org_from_vault_path("/vaults/orgs/acme/private/memories/a.yaml") == "acme"
    end
  end

  describe "memory_index_id/2" do
    test "keeps configured-org IDs and qualifies IDs for additional orgs" do
      Application.put_env(:steward_acs, :multi_tenant, true)
      Application.put_env(:steward_acs, :org_name, "prod")

      on_exit(fn ->
        Application.delete_env(:steward_acs, :multi_tenant)
        Application.delete_env(:steward_acs, :org_name)
      end)

      assert Org.memory_index_id("memory-1", "prod") == "memory-1"
      assert Org.memory_index_id("memory-1", "acme") == "acme:memory-1"
      assert Org.public_memory_id("acme:memory-1", "acme") == "memory-1"
    end
  end

  describe "org registry persistence" do
    test "persists newly created organizations in the database" do
      assert Acs.Orgs.get_by_slug("default")

      assert {:ok, org} =
               Acs.Orgs.create(%{name: "Acme", slug: "acme", subdomain: "acme"})

      assert org.slug == "acme"
      assert Acs.Orgs.get_by_slug("acme").id == org.id
    end
  end
end
