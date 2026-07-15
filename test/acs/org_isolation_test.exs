defmodule Acs.OrgIsolationTest do
  use ExUnit.Case, async: false

  alias Acs.Acs.{AgentStatus, Cache}
  alias Acs.Org
  alias Acs.Repo

  setup do
    original = Application.get_env(:steward_acs, :multi_tenant)
    original_org = Application.get_env(:steward_acs, :org_name)
    original_vault = Application.fetch_env(:steward_acs, :obsidian_vault_path)
    Application.put_env(:steward_acs, :multi_tenant, true)
    Application.put_env(:steward_acs, :org_name, "prod")
    Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    on_exit(fn ->
      Application.put_env(:steward_acs, :multi_tenant, original)

      if is_nil(original_org),
        do: Application.delete_env(:steward_acs, :org_name),
        else: Application.put_env(:steward_acs, :org_name, original_org)

      case original_vault do
        {:ok, value} -> Application.put_env(:steward_acs, :obsidian_vault_path, value)
        :error -> Application.delete_env(:steward_acs, :obsidian_vault_path)
      end

      Org.clear_request_org()
    end)

    :ok
  end

  test "cache file locks are isolated per org" do
    Org.put_request_org("acme")
    Cache.put_file_lock("lib/foo.ex", %{file_path: "lib/foo.ex", task_id: "t1"}, "acme")

    Org.put_request_org("beta")
    Cache.put_file_lock("lib/foo.ex", %{file_path: "lib/foo.ex", task_id: "t2"}, "beta")

    Org.put_request_org("acme")
    assert {:ok, %{task_id: "t1"}} = Cache.get_file_lock("lib/foo.ex", "acme")

    Org.put_request_org("beta")
    assert {:ok, %{task_id: "t2"}} = Cache.get_file_lock("lib/foo.ex", "beta")

    Org.put_request_org("acme")
    locks = Cache.get_all_file_locks()
    assert length(locks) == 1
    assert hd(locks).task_id == "t1"
  end

  test "agent status is isolated per org" do
    agent_id = "agent-#{System.unique_integer([:positive])}"

    Org.put_request_org("acme")

    {:ok, _} =
      %AgentStatus{agent_id: agent_id, org: "acme", purpose: "acme-work"}
      |> AgentStatus.changeset(%{})
      |> Repo.insert()

    Org.put_request_org("beta")
    assert AgentStatus.get(agent_id, "beta") == nil
    assert %AgentStatus{purpose: "acme-work"} = AgentStatus.get(agent_id, "acme")
  end

  test "skills store uses per-org directory in multi-tenant mode" do
    Application.put_env(:steward_acs, :obsidian_vault_path, "/vaults")

    on_exit(fn ->
      Application.delete_env(:steward_acs, :obsidian_vault_path)
    end)

    Org.put_request_org("acme")
    assert String.ends_with?(Acs.Skills.Store.skill_dir(), "/skills/orgs/acme")
  end

  test "memory index isolates identical public IDs across orgs" do
    id = "shared-#{System.unique_integer([:positive])}"

    for {org, title} <- [{"acme", "Acme memory"}, {"beta", "Beta memory"}] do
      memory =
        Acs.Memory.new(%{
          "id" => id,
          "kind" => "observation",
          "title" => title,
          "content" => title,
          "scope_path" => "test/isolation",
          "org" => org
        })

      assert {:ok, _} = Acs.Memory.Indexer.upsert_memory(memory)
    end

    assert Acs.Memory.Indexer.get_memory(id, "acme").title == "Acme memory"
    assert Acs.Memory.Indexer.get_memory(id, "beta").title == "Beta memory"

    assert {:ok, %{rows: [["acme:" <> ^id], ["beta:" <> ^id]]}} =
             Repo.query("SELECT id FROM acs_memories WHERE org IN ('acme', 'beta') ORDER BY org")
  end
end
