defmodule Acs.MultiTenantSecurityTest do
  use Acs.DataCase, async: false

  alias Acs.Acs.Cache
  alias Acs.MCP.{ErrorTrace, LogStore, ToolRequests}
  alias Acs.MCP.Tools.{DiagnosticHandlers, ErrorHandlers}
  alias Acs.Skills.Store
  alias Acs.Specs.Loader, as: SpecsLoader

  setup do
    previous_vault = Application.get_env(:steward_acs, :obsidian_vault_path)
    vault = Path.join(System.tmp_dir!(), "acs_security_#{System.unique_integer([:positive])}")
    Application.put_env(:steward_acs, :obsidian_vault_path, vault)

    on_exit(fn ->
      if previous_vault,
        do: Application.put_env(:steward_acs, :obsidian_vault_path, previous_vault),
        else: Application.delete_env(:steward_acs, :obsidian_vault_path)

      File.rm_rf(vault)
    end)

    %{vault: vault}
  end

  test "tool registry executes handlers in authenticated org context" do
    assert {:ok, %{task_id: task_id}} =
             Acs.MCP.ToolRegistry.call_tool("create_work", %{
               "_auth_org_id" => "org-a",
               "_auth_agent_id" => "agent-a",
               "_auth_role" => "collaborator",
               "agent_id" => "agent-a",
               "title" => "Tenant registry task"
             })

    assert Acs.Org.with_current("org-a", fn -> Acs.get_task(task_id) end)
    refute Acs.Org.with_current("org-b", fn -> Acs.get_task(task_id) end)
  end

  test "recent log queries and context cannot cross organizations" do
    assert :ok = LogStore.store_log(:info, "svc", "cmp", "org-a secret", %{org: "org-a"})
    assert :ok = LogStore.store_log(:info, "svc", "cmp", "org-b secret", %{org: "org-b"})

    result_a = LogStore.get_logs([org: "org-a", limit: 100], "list")
    result_b = LogStore.get_logs([org: "org-b", limit: 100], "list")

    assert Enum.any?(result_a.logs, &(&1.msg == "org-a secret"))
    refute Enum.any?(result_a.logs, &(&1.msg == "org-b secret"))
    assert Enum.any?(result_b.logs, &(&1.msg == "org-b secret"))
    refute Enum.any?(result_b.logs, &(&1.msg == "org-a secret"))

    org_a_id = Enum.find(result_a.logs, &(&1.msg == "org-a secret")).id
    context = LogStore.get_context_before(org_a_id, 100, "org-a")
    refute Enum.any?(context.logs, &(&1.msg == "org-b secret"))
  end

  test "developer key administration is tenant scoped" do
    {:ok, %{developer: dev_a}} = Acs.Developers.generate_key("a", org: "org-a")
    {:ok, %{developer: dev_b}} = Acs.Developers.generate_key("b", org: "org-b")

    assert [listed_a] = Acs.Developers.list_developers("org-a")
    assert listed_a.id == dev_a.id
    refute Acs.Developers.get_developer(dev_b.id, "org-a")
    assert {:error, :not_found} = Acs.Developers.revoke(dev_b.id, "org-a")
    assert {:ok, revoked} = Acs.Developers.revoke(dev_b.id, "org-b")
    refute revoked.active
  end

  test "tool requests are tenant scoped and duplicate names are allowed across tenants" do
    definition = %{"name" => "tenant_tool", "description" => "private"}

    assert {:ok, request_a} =
             Acs.Org.with_current("org-a", fn -> ToolRequests.create_request("a", definition) end)

    assert {:ok, request_b} =
             Acs.Org.with_current("org-b", fn -> ToolRequests.create_request("b", definition) end)

    assert [listed_a] = ToolRequests.list_requests(nil, "org-a")
    assert listed_a.id == request_a.id
    assert ToolRequests.get_request(request_b.id, "org-a") == nil
    assert ToolRequests.pending_count("org-a") == 1
    assert ToolRequests.pending_count("org-b") == 1
  end

  test "raw diagnostic SQL cannot access tenant tables" do
    assert {:error, reason} =
             DiagnosticHandlers.acs_query(%{
               "sql" => "SELECT * FROM acs_tasks",
               "purpose" => "attempt cross-tenant read"
             })

    assert reason =~ "cannot query database tables"

    assert {:ok, %{results: [%{"one" => 1}]}} =
             DiagnosticHandlers.acs_query(%{"sql" => "SELECT 1 AS one", "purpose" => "health"})
  end

  test "feedback rejects a task from another tenant" do
    {:ok, task} =
      Acs.Org.with_current("org-b", fn -> Acs.create_task(%{"title" => "B"}, "agent-b") end)

    result =
      Acs.Org.with_current("org-a", fn ->
        ErrorHandlers.acs_submit_task_feedback(%{
          "_auth_agent_id" => "agent-a",
          "agent_id" => "agent-a",
          "task_id" => task.id
        })
      end)

    assert {:error, "Task not found"} = result
  end

  test "error traces are tenant scoped" do
    assert {:ok, :created, trace_a} =
             Acs.Org.with_current("org-a", fn ->
               ErrorTrace.store_or_update_trace("svc", "cmp", "same", "secret-a")
             end)

    assert {:ok, :created, trace_b} =
             Acs.Org.with_current("org-b", fn ->
               ErrorTrace.store_or_update_trace("svc", "cmp", "same", "secret-b")
             end)

    assert trace_a.id != trace_b.id
    assert [listed_a] = ErrorTrace.list_traces(org: "org-a")
    assert listed_a.sample_message == "secret-a"
    assert ErrorTrace.get_trace(trace_b.id, "org-a") == nil
    assert {:error, :not_found} = ErrorTrace.acknowledge_trace(trace_b.id, "org-a")
  end

  test "task cache keys include organization" do
    Cache.put_task("shared-id", %{id: "shared-id", title: "A", org: "org-a"})
    Cache.put_task("shared-id", %{id: "shared-id", title: "B", org: "org-b"})

    assert {:ok, %{title: "A"}} = Cache.get_task("shared-id", "org-a")
    assert {:ok, %{title: "B"}} = Cache.get_task("shared-id", "org-b")
  end

  test "spec and skill files use tenant-specific roots", %{vault: vault} do
    specs_a = Acs.Org.with_current("org-a", &SpecsLoader.specs_path/0)
    specs_b = Acs.Org.with_current("org-b", &SpecsLoader.specs_path/0)
    skills_a = Acs.Org.with_current("org-a", &Store.skill_dir/0)
    skills_b = Acs.Org.with_current("org-b", &Store.skill_dir/0)

    assert specs_a == Path.join([vault, "specs", "orgs", "org-a"])
    assert specs_b == Path.join([vault, "specs", "orgs", "org-b"])
    assert skills_a == Path.join([vault, "skills", "orgs", "org-a"])
    assert skills_b == Path.join([vault, "skills", "orgs", "org-b"])
  end
end
