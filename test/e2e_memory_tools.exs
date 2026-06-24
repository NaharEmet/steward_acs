# test/e2e_memory_tools.exs
#
# End-to-end test for ALL ACS Memory System MCP tools via Acs.MCP.Tools.call_tool/2.
#
# Usage:
#   cd ..
#   MIX_ENV=test mix run test/e2e_memory_tools.exs

Code.require_file("test_helper.exs", __DIR__)

alias Acs.Repo
alias Acs.Memory.Loader
alias Acs.Memory.Indexer

IO.puts("\n═══ ACS Memory System - E2E Tool Verification ═══\n")

# ─── Step 0: Initialize ───
IO.puts("Step 0: Check out DB connection and sync index...")

# The test_helper sets sandbox to :manual; we need to check out a connection
# and set shared mode so all processes in this script can use the Repo.
Ecto.Adapters.SQL.Sandbox.checkout(Repo)
Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

{:ok, init_count, init_quarantined} = Indexer.sync_all()
IO.puts("🟢 Index initialized: #{init_count} memories synced, #{length(init_quarantined)} quarantined\n")

# State accumulator
state = %{ids: [], pass: 0, fail: 0}

# Helper lambdas
ph = fn title -> IO.puts("─── #{title} ───") end

record_pass = fn msg ->
  IO.puts("  🟢 PASS: #{msg}")
end

record_fail = fn msg ->
  IO.puts("  🔴 FAIL: #{msg}")
end

# Pre-clean: remove any leftover YAML from a prior aborted run
scope_path = "agent_coordination_system/memory/e2e_test"
legacy_path = Loader.memory_dir() |> Path.join(scope_path <> ".yaml")
if File.exists?(legacy_path) do
  File.rm!(legacy_path)
  IO.puts("  🗑️ Cleaned leftover file: #{legacy_path}")
end

# ─── Test 1: save_memory (first) ───
ph.("Test 1: save_memory - create first memory (axiom)")

result1 =
  Acs.MCP.Tools.call_tool("save_memory", %{
    "kind" => "axiom",
    "title" => "E2E Test: File watchers need debounce",
    "content" =>
      "File watchers without debounce cause race conditions on rapid file changes. Always use a debounce interval of at least 100ms.",
    "scope_path" => scope_path,
    "tags" => ["debounce", "file_watcher", "race-condition", "filesystem"],
    "importance" => 4
  })

{state, mem1_id} =
  case result1 do
    {:ok, %{id: id, status: "proposed", conflict_flags: _}} ->
      record_pass.("save_memory #1 -> id=#{id}, status=proposed")
      {%{state | ids: [id | state.ids], pass: state.pass + 1}, id}

    {:ok, data} ->
      record_fail.("save_memory #1 unexpected format: #{inspect(data)}")
      {%{state | fail: state.fail + 1}, nil}

    {:error, reason} ->
      record_fail.("save_memory #1 error: #{inspect(reason)}")
      {%{state | fail: state.fail + 1}, nil}
  end

IO.puts("")

# ─── Test 2: set_memory_status - approve first memory ───
ph.("Test 2: set_memory_status - approve first memory")

state =
  if mem1_id do
    result2 =
      Acs.MCP.Tools.call_tool("set_memory_status", %{
        "memory_id" => mem1_id,
        "status" => "approved"
      })

    case result2 do
      {:ok, %{status: "approved", memory_id: id}} when id == mem1_id ->
        record_pass.("set_memory_status #{mem1_id} -> status=approved")
        %{state | pass: state.pass + 1}

      {:ok, data} ->
        record_fail.("set_memory_status unexpected format: #{inspect(data)}")
        %{state | fail: state.fail + 1}

      {:error, reason} ->
        record_fail.("set_memory_status error: #{inspect(reason)}")
        %{state | fail: state.fail + 1}
    end
  else
    record_fail.("set_memory_status skipped: no memory ID from Test 1")
    %{state | fail: state.fail + 1}
  end

IO.puts("")

# ─── Test 3: save_memory again with overlapping tags (conflict detection) ───
# The first memory is now approved at the same scope with tags ["debounce","file_watcher","race-condition","filesystem"].
# This save shares all 4 tags → >= 3 threshold → conflict flags expected.
ph.("Test 3: save_memory - create second memory with overlapping tags")

result3 =
  Acs.MCP.Tools.call_tool("save_memory", %{
    "kind" => "learning",
    "title" => "E2E Test: Debounce interval of 100ms minimum",
    "content" =>
      "When implementing file watchers, the debounce interval should never be below 100ms to avoid race conditions on rapid file changes.",
    "scope_path" => scope_path,
    "tags" => ["debounce", "file_watcher", "race-condition", "filesystem"],
    "importance" => 3
  })

{state, mem2_id} =
  case result3 do
    {:ok, %{id: id, status: "proposed", conflict_flags: flags}} when is_list(flags) and flags != [] ->
      record_pass.(
        "save_memory #2 with #{length(flags)} conflict flag(s): #{inspect(flags)}"
      )

      {%{state | ids: [id | state.ids], pass: state.pass + 1}, id}

    {:ok, %{id: id, status: "proposed", conflict_flags: []}} ->
      record_fail.("save_memory #2 expected conflict flags but got empty list")
      {%{state | ids: [id | state.ids], fail: state.fail + 1}, id}

    {:ok, %{id: id}} ->
      record_fail.("save_memory #2 missing conflict_flags key entirely")
      {%{state | ids: [id | state.ids], fail: state.fail + 1}, id}

    {:ok, data} ->
      record_fail.("save_memory #2 unexpected format: #{inspect(data)}")
      {%{state | fail: state.fail + 1}, nil}

    {:error, reason} ->
      record_fail.("save_memory #2 error: #{inspect(reason)}")
      {%{state | fail: state.fail + 1}, nil}
  end

IO.puts("")

# ─── Test 4: list_memories ───
ph.("Test 4: list_memories - filter by scope_path")

result4 =
  Acs.MCP.Tools.call_tool("list_memories", %{
    "scope_path" => scope_path
  })

state =
  case result4 do
    {:ok, %{memories: mems, count: count}} when count >= 2 ->
      ids = Enum.map(mems, & &1.id)
      record_pass.("list_memories found #{count} memories at scope: #{inspect(ids)}")
      %{state | pass: state.pass + 1}

    {:ok, %{memories: mems, count: count}} ->
      record_fail.("list_memories expected >= 2 memories, got #{count}: #{inspect(mems)}")
      %{state | fail: state.fail + 1}

    {:ok, data} ->
      record_fail.("list_memories unexpected format: #{inspect(data)}")
      %{state | fail: state.fail + 1}

    {:error, reason} ->
      record_fail.("list_memories error: #{inspect(reason)}")
      %{state | fail: state.fail + 1}
  end

IO.puts("")

# ─── Test 5: search_memories ───
ph.("Test 5: search_memories - full-text search by query")

  result5 =
    Acs.MCP.Tools.call_tool("search_memories", %{
      "query" => "debounce"
    })

  state =
    case result5 do
      {:ok, %{memories: mems, count: count}} when count >= 1 ->
        titles = Enum.map(mems, & &1.title)
        record_pass.("search_memories for 'debounce' found #{count} result(s): #{inspect(titles)}")
        %{state | pass: state.pass + 1}

      {:ok, %{memories: [], count: 0}} ->
        record_fail.("search_memories found 0 results for 'debounce'")
        %{state | fail: state.fail + 1}

    {:ok, data} ->
      record_fail.("search_memories unexpected format: #{inspect(data)}")
      %{state | fail: state.fail + 1}

    {:error, reason} ->
      record_fail.("search_memories error: #{inspect(reason)}")
      %{state | fail: state.fail + 1}
  end

IO.puts("")

# ─── Test 6: set_memory_status - reject second memory ───
ph.("Test 6: set_memory_status - reject the second (learning) memory")

state =
  if mem2_id do
    result6 =
      Acs.MCP.Tools.call_tool("set_memory_status", %{
        "memory_id" => mem2_id,
        "status" => "rejected"
      })

    case result6 do
      {:ok, %{status: "rejected", memory_id: id}} when id == mem2_id ->
        record_pass.("set_memory_status #{mem2_id} -> status=rejected")
        %{state | pass: state.pass + 1}

      {:ok, data} ->
        record_fail.("set_memory_status unexpected format: #{inspect(data)}")
        %{state | fail: state.fail + 1}

      {:error, reason} ->
        record_fail.("set_memory_status error: #{inspect(reason)}")
        %{state | fail: state.fail + 1}
    end
  else
    record_fail.("set_memory_status skipped: no mem2_id available")
    %{state | fail: state.fail + 1}
  end

IO.puts("")

# ─── Test 7: set_memory_status - mark approved memory as stale ───
ph.("Test 7: set_memory_status - mark approved memory as stale")

state =
  if mem1_id do
    result7 =
      Acs.MCP.Tools.call_tool("set_memory_status", %{
        "memory_id" => mem1_id,
        "status" => "stale"
      })

    case result7 do
      {:ok, %{status: "stale", memory_id: id}} when id == mem1_id ->
        record_pass.("set_memory_status #{mem1_id} -> status=stale")
        %{state | pass: state.pass + 1}

      {:ok, data} ->
        record_fail.("set_memory_status unexpected format: #{inspect(data)}")
        %{state | fail: state.fail + 1}

      {:error, reason} ->
        record_fail.("set_memory_status error: #{inspect(reason)}")
        %{state | fail: state.fail + 1}
    end
  else
    record_fail.("set_memory_status skipped: no mem1_id available")
    %{state | fail: state.fail + 1}
  end

IO.puts("")

# ─── Test 8: generate_guidance_packet ───
ph.("Test 8: generate_guidance_packet - generate for scope")

result8 =
  Acs.MCP.Tools.call_tool("generate_guidance_packet", %{
    "scope_path" => scope_path
  })

state =
  case result8 do
    {:ok, packet} when is_map(packet) ->
      has_scope = Map.has_key?(packet, :scope) or Map.has_key?(packet, "scope")
      has_critical = Map.has_key?(packet, :critical_axioms) or Map.has_key?(packet, "critical_axioms")

      cond do
        has_scope and has_critical ->
          scope_val = packet[:scope] || packet["scope"]
          axioms = packet[:critical_axioms] || packet["critical_axioms"] || []
          record_pass.(
            "generate_guidance_packet for scope '#{scope_val}' returned #{map_size(packet)} keys, #{length(axioms)} axiom(s)"
          )

          %{state | pass: state.pass + 1}

        true ->
          record_fail.("generate_guidance_packet missing scope or critical_axioms keys: #{inspect(Map.keys(packet))}")
          %{state | fail: state.fail + 1}
      end

    {:error, reason} ->
      record_fail.("generate_guidance_packet error: #{inspect(reason)}")
      %{state | fail: state.fail + 1}
  end

IO.puts("")

# ─── Summary ───
IO.puts("═══ Summary ═══")
IO.puts("Pass: #{state.pass}  |  Fail: #{state.fail}")

if state.fail == 0 do
  IO.puts("\n🎉 ALL 8 TESTS PASSED!")
else
  IO.puts("\n❌ #{state.fail} TEST(S) FAILED")
end

# ─── Cleanup ───
IO.puts("\n─── Cleanup ───")

# Remove from index
Enum.each(state.ids, fn id ->
  case Indexer.get_memory(id) do
    nil ->
      :ok

    schema ->
      file_path = schema.file_path

      if is_binary(file_path) and File.exists?(file_path) do
        File.rm!(file_path)
        IO.puts("  🗑️ Deleted YAML: #{file_path}")
      end

      Indexer.remove_memory(id)
      IO.puts("  🗑️ Removed from index: #{id}")
  end
end)

# Also clean up any leftover YAML at the test scope path
if File.exists?(legacy_path) do
  File.rm!(legacy_path)
  IO.puts("  🗑️ Cleaned leftover: #{legacy_path}")
end

IO.puts("Cleanup complete\n")

# Set exit code
if state.fail > 0 do
  System.halt(1)
else
  :ok
end
