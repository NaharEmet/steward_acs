defmodule Acs.TenantIsolationTest do
  use Acs.DataCase, async: false

  alias Acs.Acs.Task
  alias Acs.Memory.{Indexer, Loader}

  setup do
    previous_org = Application.get_env(:steward_acs, :org_name)
    previous_store = Application.get_env(:steward_acs, :memory_store)
    previous_vault = Application.get_env(:steward_acs, :obsidian_vault_path)
    vault = Path.join(System.tmp_dir!(), "acs_tenant_#{System.unique_integer([:positive])}")

    Application.put_env(:steward_acs, :memory_store, "obsidian")
    Application.put_env(:steward_acs, :obsidian_vault_path, vault)

    on_exit(fn ->
      restore_env(:org_name, previous_org)
      restore_env(:memory_store, previous_store)
      restore_env(:obsidian_vault_path, previous_vault)
      File.rm_rf(vault)
    end)

    %{vault: vault}
  end

  test "request-local org scopes task creation and ignores caller org overrides" do
    Acs.Org.with_current("org-a", fn ->
      assert {:ok, task} = Acs.create_task(%{"title" => "A", "org" => "org-b"}, "agent")
      assert task.org == "org-a"
    end)

    assert [%Task{title: "A"}] = Acs.Org.with_current("org-a", fn -> Acs.Acs.list_tasks() end)
    assert [] = Acs.Org.with_current("org-b", fn -> Acs.Acs.list_tasks() end)
  end

  test "same public memory id is isolated in index and Obsidian paths" do
    a = memory("org-a", "shared")
    b = memory("org-b", "shared")

    assert :ok = Loader.save(a)
    assert :ok = Loader.save(b)
    assert Loader.memory_to_path(a) != Loader.memory_to_path(b)
    assert File.exists?(Loader.memory_to_path(a))
    assert File.exists?(Loader.memory_to_path(b))

    assert {:ok, _} = Indexer.upsert_memory(a)
    assert {:ok, _} = Indexer.upsert_memory(b)

    assert Indexer.get_memory("shared", "org-a").content == "content for org-a"
    assert Indexer.get_memory("shared", "org-b").content == "content for org-b"
  end

  test "session identity is global and tenant authorization is enforced separately" do
    {:ok, user} = Acs.Accounts.register_user(%{email: "admin@example.test", org: "org-a"})
    token = Acs.Accounts.generate_user_session_token(user)

    assert Acs.Accounts.get_user_by_session_token(token, "org-a").id == user.id
    assert Acs.Accounts.get_user_by_session_token(token, "org-b").id == user.id
  end

  defp memory(org, id) do
    Acs.Memory.new(%{
      "id" => id,
      "kind" => "observation",
      "status" => "approved",
      "title" => "Shared",
      "content" => "content for #{org}",
      "scope_path" => "shared/scope",
      "importance" => 3,
      "org" => org
    })
  end

  defp restore_env(key, nil), do: Application.delete_env(:steward_acs, key)
  defp restore_env(key, value), do: Application.put_env(:steward_acs, key, value)
end
