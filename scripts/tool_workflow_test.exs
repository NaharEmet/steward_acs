IO.puts("=== help with level filter ===")
{:ok, result} = Acs.MCP.Tools.call_tool("help", %{"level" => 1})
IO.puts("Total tools at level 1: #{result["total_tools"]}")

IO.puts("\n=== get_present_status with sleeping filter ===")
{:ok, result2} = Acs.MCP.Tools.call_tool("get_present_status", %{"status_filter" => "sleeping"})
IO.puts("Sleeping agents: #{inspect(result2)}")

IO.puts("\n=== connection_diagnostic with llm ===")
{:ok, result3} = Acs.MCP.Tools.call_tool("connection_diagnostic", %{"service" => "llm"})
IO.puts("LLM diagnostic: #{inspect(result3)}")

IO.puts("\n=== query tables ===")
sql = "SELECT name FROM sqlite_master WHERE type = 'table'"
{:ok, result4} = Acs.MCP.Tools.call_tool("query", %{"sql" => sql, "purpose" => "list tables"})
IO.puts("Tables: #{inspect(result4)}")

IO.puts("\n=== Full workflow ===")

{:ok, task} = Acs.MCP.Tools.call_tool("create_work", %{
  "_auth_role" => "admin", "_auth_agent_id" => "test_runner",
  "agent_id" => "test_runner", "title" => "Workflow test #{:erlang.system_time(:second)}"
})
task_id = task[:task_id]
IO.puts("1. Created task: #{inspect(task)}")

{:ok, claim} = Acs.MCP.Tools.call_tool("claim_work", %{
  "_auth_role" => "admin", "_auth_agent_id" => "test_runner",
  "agent_id" => "test_runner", "task_id" => task_id
})
IO.puts("2. Claimed: #{inspect(claim)}")

{:ok, lock} = Acs.MCP.Tools.call_tool("lock_file", %{
  "_auth_role" => "admin", "_auth_agent_id" => "test_runner",
  "agent_id" => "test_runner", "task_id" => task_id, "file_path" => "test/workflow_test.txt"
})
IO.puts("3. Lock: #{inspect(lock)}")

{:ok, locked} = Acs.MCP.Tools.call_tool("get_locked_files", %{})
IO.puts("4. Locked files count: #{length(locked)}")

{:ok, unlock} = Acs.MCP.Tools.call_tool("unlock_file", %{
  "_auth_role" => "admin", "_auth_agent_id" => "test_runner",
  "agent_id" => "test_runner", "file_path" => "test/workflow_test.txt"
})
IO.puts("5. Unlock: #{inspect(unlock)}")

{:ok, release} = Acs.MCP.Tools.call_tool("release_work", %{
  "_auth_role" => "admin", "_auth_agent_id" => "test_runner",
  "agent_id" => "test_runner", "task_id" => task_id
})
IO.puts("6. Released: #{inspect(release)}")

IO.puts("\n=== All done! ===")
