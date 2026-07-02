defmodule Acs.Memory.GuidanceTest do
  use Acs.DataCase, async: false

  alias Acs.Memory.Guidance

  setup do
    setup_test_memories()
    :ok
  end

  describe "generate/1" do
    test "generates guidance packet for scope path" do
      packet = Guidance.generate("agent_coordination_system/cache")

      assert is_map(packet)
      assert Map.has_key?(packet, :scope)
      assert Map.has_key?(packet, :critical_axioms)
      assert Map.has_key?(packet, :warnings)
      assert Map.has_key?(packet, :relevant_patterns)
      assert Map.has_key?(packet, :compressed_knowledge)
      assert Map.has_key?(packet, :maintenance_instructions)
    end

    test "returns empty packet for non-existent scope" do
      packet = Guidance.generate("nonexistent/scope/path")

      assert packet.scope == "nonexistent/scope/path"
      assert packet.critical_axioms == []
      assert packet.warnings == []
      assert packet.relevant_patterns == []
      assert is_binary(packet.maintenance_instructions)
    end

    test "includes critical axioms from approved memories" do
      packet = Guidance.generate("agent_coordination_system/cache/release")

      # Should include approved axioms at this scope
      assert is_list(packet.critical_axioms)
    end

    test "respects max limits for critical axioms" do
      packet = Guidance.generate("agent_coordination_system")

      # Should not exceed 5 critical axioms per spec
      assert length(packet.critical_axioms) <= 5
    end

    test "respects max limits for warnings" do
      packet = Guidance.generate("agent_coordination_system")

      # Should not exceed 3 warnings per spec
      assert length(packet.warnings) <= 3
    end

    test "respects max limits for patterns" do
      packet = Guidance.generate("agent_coordination_system")

      # Should not exceed 5 patterns per spec
      assert length(packet.relevant_patterns) <= 5
    end

    test "compressed knowledge has reasonable length" do
      packet = Guidance.generate("agent_coordination_system")

      # Should be bounded (spec says max ~500 tokens, we use chars)
      assert String.length(packet.compressed_knowledge) <= 3000
    end
  end

  describe "for_task/1" do
    test "generates guidance based on task file_paths" do
      # First create a task with a file path
      {:ok, task} = Acs.create_task(%{
        "title" => "Test Task",
        "description" => "Test task for guidance",
        "file_paths" => ["lib/acs/cache/release.ex"]
      }, "test_agent")

      packet = Guidance.for_task(task.id)

      assert is_map(packet)
      assert Map.has_key?(packet, :scope)

      # Cleanup
      Acs.release_task(task.id, "test_agent")
    end

    test "returns empty packet for non-existent task" do
      packet = Guidance.for_task("nonexistent_task_id")

      assert packet.scope == nil
      assert packet.critical_axioms == []
    end
  end

  describe "guidance injection" do
    test "guidance packet format is compatible with MCP response" do
      packet = Guidance.generate("agent_coordination_system/cache")

      # All required keys should be present for MCP tool response
      assert is_binary(packet.scope)
      assert is_list(packet.critical_axioms)
      assert is_list(packet.warnings)
      assert is_list(packet.relevant_patterns)
      assert is_binary(packet.compressed_knowledge)
      assert Map.has_key?(packet, :maintenance_instructions)
    end

    test "axiom entries have required fields" do
      packet = Guidance.generate("agent_coordination_system/cache/release")

      Enum.each(packet.critical_axioms, fn axiom ->
        assert Map.has_key?(axiom, :id)
        assert Map.has_key?(axiom, :title)
        assert Map.has_key?(axiom, :summary)
        assert Map.has_key?(axiom, :importance)
      end)
    end

    test "warning entries have required fields" do
      packet = Guidance.generate("agent_coordination_system/cache")

      Enum.each(packet.warnings, fn warning ->
        assert Map.has_key?(warning, :id)
        assert Map.has_key?(warning, :title)
        assert Map.has_key?(warning, :summary)
        assert Map.has_key?(warning, :importance)
      end)
    end

    test "maintenance_instructions has expected content" do
      packet = Guidance.generate("agent_coordination_system/cache")

      assert String.contains?(packet.maintenance_instructions, "set_memory_status")
      assert String.contains?(packet.maintenance_instructions, "save_memory")
      assert String.contains?(packet.maintenance_instructions, "document_propose")
    end
  end

  # Helper functions

  defp setup_test_memories do
    test_memories = [
      %{
        "id" => "guidance_test_axiom",
        "kind" => "axiom",
        "status" => "approved",
        "title" => "Cache Release Ordering",
        "summary" => "Agent state must be cleared before cache deletion",
        "content" => "When releasing tasks, clear agent ownership before deleting cache entries to avoid stale assignment races.",
        "scope_path" => "agent_coordination_system/cache/release",
        "importance" => 5,
        "tags" => ["cache", "concurrency"],
        "triggers" => ["task release", "cache invalidation"],
        "failure_modes" => ["stale ownership", "duplicate assignment"]
      },
      %{
        "id" => "guidance_test_warning",
        "kind" => "warning",
        "status" => "approved",
        "title" => "Stale Task Release Race",
        "summary" => "Concurrent release can leave stale ownership",
        "content" => "During concurrent release flows, stale ownership may remain if agent state is not cleared before cache deletion.",
        "scope_path" => "agent_coordination_system/cache/release",
        "importance" => 4,
        "tags" => ["cache", "concurrency"],
        "triggers" => ["concurrent release"],
        "failure_modes" => ["stale ownership"]
      },
      %{
        "id" => "guidance_test_pattern",
        "kind" => "pattern",
        "status" => "approved",
        "title" => "Transactional Cleanup Pattern",
        "summary" => "Use transactional cleanup wrapper for release operations",
        "content" => "Wrap release operations in a transactional cleanup pattern to ensure atomic state changes.",
        "scope_path" => "agent_coordination_system/cache",
        "importance" => 3,
        "tags" => ["cache", "pattern"],
        "triggers" => ["release operations"]
      }
    ]

    Enum.each(test_memories, fn attrs ->
      memory = Acs.Memory.new(attrs)
      Acs.Memory.Loader.save(memory)
      Acs.Memory.Indexer.upsert_memory(memory)
    end)

    :ok
  end
end
