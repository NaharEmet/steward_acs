defmodule Acs.MCP.Tools.IdLeakTest do
  use Acs.DataCase, async: false

  alias Acs.MCP.Tools.{
    AdminHandlers,
    AuthorityHandlers,
    CoreHandlers,
    ErrorHandlers,
    PersonHandlers
  }

  alias Acs.MCP.Tools

  setup do
    org = Acs.Org.current()
    %{org: org}
  end

  test "get_locked_files exposes the task slug, never the file-lock or task DB id", %{org: org} do
    task =
      Acs.Org.with_current(org, fn ->
        {:ok, t} = Acs.create_task(%{"title" => "Locked file task"}, "lock-agent")
        {:ok, t, _guidance} = Acs.claim_task(t.slug, "lock-agent")
        t
      end)

    Acs.Org.with_current(org, fn ->
      assert {:ok, %{status: "locked"}} =
               Acs.lock_file("lib/idleak/file.ex", "lock-agent", task.slug)
    end)

    assert {:ok, locks} =
             Acs.Org.with_current(org, fn -> CoreHandlers.acs_get_locked_files(%{}) end)

    assert [lock] = locks
    refute Map.has_key?(lock, :id)
    assert lock.locked_by_agent == "lock-agent"
    assert lock.task_id == task.slug
  end

  test "list_error_traces maps task_id to the public slug", %{org: org} do
    task =
      Acs.Org.with_current(org, fn ->
        {:ok, t} = Acs.create_task(%{"title" => "Error trace linked task"}, "trace-agent")
        t
      end)

    Acs.Org.with_current(org, fn ->
      {:ok, _action, trace} =
        Acs.MCP.ErrorTrace.store_or_update_trace(
          "svc",
          "idleak-cmp",
          "idleak boom pattern",
          "boom"
        )

      {:ok, _} = Acs.MCP.ErrorTrace.mark_tasked(trace.id, task.id)

      assert {:ok, %{traces: [formatted]}} =
               ErrorHandlers.list_error_traces(%{"component" => "idleak-cmp"})

      assert formatted.task_id == task.slug
    end)
  end

  test "list_authority_levels omits the level DB id", %{org: org} do
    assert {:ok, %{levels: levels}} =
             AuthorityHandlers.list_authority_levels(%{"_auth_org_id" => org})

    assert levels != []
    refute Enum.any?(levels, &Map.has_key?(&1, :id))
    assert Enum.all?(levels, &(&1.slug in ["high", "elevated", "standard"]))
  end

  test "person status responses omit the person DB id", %{org: org} do
    assert {:ok, %{found: false}} =
             PersonHandlers.get_person_status(%{"name" => "No Id Person", "_auth_org" => org})

    assert {:ok, %{person: saved}} =
             PersonHandlers.set_person_status(%{
               "name" => "No Id Person",
               "email" => "noid@acme.com",
               "status" => "Engineer",
               "rank" => "standard",
               "_auth_agent_id" => "alice@acme.com"
             })

    refute Map.has_key?(saved, :id)

    assert {:ok, %{found: true, status: "Engineer"}} =
             PersonHandlers.get_person_status(%{"email" => "noid@acme.com"})
  end

  test "developer key lifecycle responses omit the developer DB id", %{org: org} do
    assert {:ok, %{key: _key, developer_name: "idleak-dev", role: "collaborator", org: ^org}} =
             AdminHandlers.generate_key(%{
               "name" => "idleak-dev",
               "role" => "collaborator",
               "_auth_org_id" => org
             })

    assert {:ok, %{developers: devs}} = AdminHandlers.list_keys(%{"_auth_org_id" => org})

    assert Enum.any?(devs, &(&1.developer_name == "idleak-dev"))
    refute Enum.any?(devs, &Map.has_key?(&1, :id))

    assert {:ok, %{developer_name: "idleak-dev", active: false, status: "revoked"}} =
             AdminHandlers.revoke_key(%{"developer_name" => "idleak-dev", "_auth_org_id" => org})
  end

  test "chat get_started pending_reminders expose the slug, never the task DB id", %{org: org} do
    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
    due = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    Acs.Org.with_current(org, fn ->
      assert {:ok, _} =
               Tools.call_tool(
                 "create_work",
                 %{
                   "title" => "Chat leak reminder",
                   "kind" => "user",
                   "due_at" => DateTime.to_iso8601(due),
                   "remind_at" => DateTime.to_iso8601(past),
                   "_auth_agent_id" => "Nahar",
                   "_auth_org_id" => org,
                   "_auth_role" => "member",
                   "_auth_audience" => "chat"
                 }
               )

      assert {:ok, packet} =
               Tools.call_tool("steward_ask", %{
                 "_auth_agent_id" => "Nahar",
                 "_auth_role" => "member",
                 "_auth_audience" => "chat",
                 "_auth_org_id" => org
               })

      assert Enum.any?(packet.pending_reminders, &(&1.slug == "chat-leak-reminder"))
      refute Enum.any?(packet.pending_reminders, &Map.has_key?(&1, :id))
    end)
  end
end
