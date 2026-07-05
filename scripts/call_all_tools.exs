defmodule ToolTester do
  @admin_auth %{"_auth_role" => "admin", "_auth_agent_id" => "test_runner"}

  def run do
    IO.puts("\n=== CALLING ALL MCP TOOLS ===\n")

    results = [
      call_help(),
      call_help_cat(),
      call_config_lookup(),
      call_connection_diagnostic(),
      call_connection_diagnostic_db(),
      call_get_locked_files(),
      call_list_plugins(),
      call_app_list(),
      call_time_get(),
      call_get_logs(),
      call_list_orgs(),
      call_list_error_traces(),
      call_memory_health_check(),
      call_list_memories(),
      call_specs_list(),
      call_specs_list_undocumented(),
      call_generate_guidance_packet(),
      call_ask(),
      call_get_present_status(),
      call_create_work(),
      call_list_tasks(),
      call_time_set(),
      call_query(),
      call_save_memory(),
      call_search_memories(),
      call_specs_search(),
      call_specs_propose(),
      call_app_configure(),
      call_app_remove(),
      call_wake_not_sleeping(),
      call_unlock_not_locked(),
      call_claim_work_bad_task(),
      call_release_work_bad_task(),
      call_lock_file_bad_task(),
      call_submit_feedback_bad_task(),
      call_set_memory_bad_id(),
      call_specs_get_bad(),
      call_ack_bad_trace(),
      call_resolve_bad_trace(),
      call_create_task_bad_trace(),
      call_specs_approve(),
      call_specs_reject(),
    ]

    ok_count = Enum.count(results, fn {_name, result} -> match?({:ok, _}, result) end)
    err_count = Enum.count(results, fn {_name, result} -> match?({:error, _}, result) end)

    IO.puts("\n========================================")
    IO.puts("ALL TOOL CALLS COMPLETE")
    IO.puts("Total: #{length(results)}, OK: #{ok_count}, Errors: #{err_count}")
    IO.puts("========================================")
  end

  defp try_call(name, args) do
    IO.write("  #{name}: ")

    result =
      try do
        Acs.MCP.Tools.call_tool(name, args)
      rescue
        e -> {:error, "EXCEPTION: #{inspect(e)}"}
      end

    case result do
      {:ok, _} -> IO.puts("OK")
      {:error, reason} -> IO.puts("ERROR: #{inspect(reason)}")
      {:sleep, _, _} -> IO.puts("OK (sleep signal)")
    end

    {name, result}
  end

  defp call_help, do: try_call("help", %{})
  defp call_help_cat, do: try_call("help", %{"category" => "acs_core"})
  defp call_config_lookup, do: try_call("config_lookup", %{})
  defp call_connection_diagnostic, do: try_call("connection_diagnostic", %{})
  defp call_connection_diagnostic_db, do: try_call("connection_diagnostic", %{"service" => "database", "verbose" => true})
  defp call_get_locked_files, do: try_call("get_locked_files", %{})
  defp call_list_plugins, do: try_call("list_plugins", %{})
  defp call_app_list, do: try_call("app_list", %{})
  defp call_time_get, do: try_call("time", %{"action" => "get"})
  defp call_get_logs, do: try_call("get_logs", %{"limit" => 3, "mode" => "summary"})
  defp call_list_orgs, do: try_call("list_orgs", %{})
  defp call_list_error_traces, do: try_call("list_error_traces", %{})
  defp call_memory_health_check, do: try_call("memory_health_check", %{})
  defp call_list_memories, do: try_call("list_memories", %{"limit" => 3})
  defp call_specs_list, do: try_call("specs_list", %{})
  defp call_specs_list_undocumented, do: try_call("specs_list_undocumented", %{})
  defp call_generate_guidance_packet, do: try_call("generate_guidance_packet", %{})
  defp call_ask, do: try_call("ask", %{"limit" => 3})
  defp call_get_present_status, do: try_call("get_present_status", %{})
  defp call_time_set, do: try_call("time", Map.merge(@admin_auth, %{"action" => "set", "seconds" => 0}))
  defp call_query, do: try_call("query", %{"sql" => "SELECT 1", "purpose" => "tool test"})

  defp call_create_work, do: try_call("create_work", Map.merge(@admin_auth, %{"agent_id" => "test_runner", "title" => "Tool tester test task"}))
  defp call_list_tasks, do: try_call("list_tasks", Map.merge(@admin_auth, %{"agent_id" => "test_runner"}))
  defp call_wake_not_sleeping, do: try_call("wake", Map.merge(@admin_auth, %{"agent_id" => "test_runner"}))
  defp call_unlock_not_locked, do: try_call("unlock_file", Map.merge(@admin_auth, %{"agent_id" => "test_runner", "file_path" => "test/not_locked.txt"}))
  defp call_claim_work_bad_task, do: try_call("claim_work", Map.merge(@admin_auth, %{"agent_id" => "test_runner", "task_id" => "nonexistent"}))
  defp call_release_work_bad_task, do: try_call("release_work", Map.merge(@admin_auth, %{"agent_id" => "test_runner", "task_id" => "nonexistent"}))
  defp call_lock_file_bad_task, do: try_call("lock_file", Map.merge(@admin_auth, %{"agent_id" => "test_runner", "task_id" => "nonexistent", "file_path" => "test/file.txt"}))
  defp call_submit_feedback_bad_task, do: try_call("submit_task_feedback", %{"task_id" => "nonexistent"})

  defp call_save_memory, do: try_call("save_memory", %{"kind" => "observation", "title" => "Test memory from tool tester", "content" => "This is a test memory.", "scope_path" => "test/tool_test", "importance" => 1, "tags" => ["test"]})
  defp call_search_memories, do: try_call("search_memories", %{"query" => "test", "limit" => 3})
  defp call_set_memory_bad_id, do: try_call("set_memory_status", %{"memory_id" => "nonexistent", "status" => "approved"})
  defp call_specs_search, do: try_call("specs_search", %{"query" => "test", "limit" => 3})
  defp call_specs_propose, do: try_call("specs_propose", %{"app" => "steward_acs", "path" => "test/tool_tester", "title" => "Test Spec", "purpose" => "Testing", "content" => "Test"})
  defp call_specs_get_bad, do: try_call("specs_get", %{"app" => "steward_acs", "path" => "nonexistent"})
  defp call_specs_approve, do: try_call("specs_approve", %{"app" => "steward_acs", "path" => "test/tool_tester", "reviewer" => "tool_tester"})
  defp call_specs_reject, do: try_call("specs_reject", %{"app" => "steward_acs", "path" => "test/tool_tester"})

  defp call_ack_bad_trace, do: try_call("ack_error_trace", %{"trace_id" => "nonexistent"})
  defp call_resolve_bad_trace, do: try_call("resolve_error_trace", %{"trace_id" => "nonexistent"})
  defp call_create_task_bad_trace, do: try_call("create_task_from_error_trace", %{"trace_id" => "nonexistent"})

  defp call_app_configure, do: try_call("app_configure", %{"name" => "test_app", "base_url" => "http://localhost:9999"})
  defp call_app_remove, do: try_call("app_remove", %{"name" => "test_app"})
end

ToolTester.run()
