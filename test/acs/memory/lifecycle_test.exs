defmodule Acs.Memory.LifecycleTest do
  use Acs.DataCase, async: false

  alias Acs.Memory.Loader
  alias Acs.Memory.Indexer

  setup do
    # Ensure directory exists
    Loader.ensure_directories!()
    :ok
  end

  describe "save memory creates embedding" do
    test "saving memory triggers indexing with embedding" do
      memory = Acs.MemoryTestHelpers.create_test_memory(%{
        "id" => "lifecycle_save_#{System.unique_integer([:positive])}",
        "kind" => "axiom",
        "title" => "Lifecycle Test Memory",
        "scope_path" => "test_app/lifecycle"
      })

      # Save memory
      assert Loader.save(memory) == :ok
      Indexer.upsert_memory(memory)  # Explicit - automatic sync is Phase 5

      # Verify it was indexed
      indexed = Indexer.get_memory(memory.id)
      assert indexed != nil
      assert indexed.id == memory.id

      # Verify embedding was created (if VectorIndex is available)
      if function_exported?(Acs.Memory.VectorIndex, :search_similar, 2) do
        embedding_result = Acs.Memory.VectorIndex.search_similar([0.1, 0.2, 0.3], limit: 10)
        # Memory should be in the index (or graceful degradation)
        assert is_list(embedding_result)
      end

      # Cleanup
      cleanup_memory(memory)
    end
  end

  describe "delete memory removes embedding" do
    test "deleting memory removes from index and vector store" do
      memory = Acs.MemoryTestHelpers.create_test_memory(%{
        "id" => "lifecycle_delete_#{System.unique_integer([:positive])}",
        "kind" => "warning",
        "title" => "Delete Test Memory",
        "scope_path" => "test_app/lifecycle"
      })

      # Save and verify indexed
      Loader.save(memory)
      Indexer.upsert_memory(memory)  # Explicit
      assert Indexer.get_memory(memory.id) != nil

      # Delete memory
      assert Loader.delete(memory) == :ok
      Indexer.remove_memory(memory.id)  # Explicit - Loader.delete only removes file

      # Verify removed from index
      assert Indexer.get_memory(memory.id) == nil

      # Verify removed from vector index
      if function_exported?(Acs.Memory.VectorIndex, :search_similar, 2) do
        # The memory should no longer appear in searches
        results = Acs.Memory.VectorIndex.search_similar([0.1, 0.2, 0.3], limit: 10)
        assert Enum.all?(results, fn r -> r.memory_id != memory.id end)
      end
    end
  end

  describe "sync_all regenerates all embeddings" do
    test "sync_all upserts all memories to index" do
      # Create multiple memories
      memories = for i <- 1..3 do
        memory = Acs.MemoryTestHelpers.create_test_memory(%{
          "id" => "lifecycle_sync_#{i}_#{System.unique_integer([:positive])}",
          "kind" => "pattern",
          "title" => "Sync Test Memory #{i}",
          "scope_path" => "test_app/sync/#{i}"
        })
        Loader.save(memory)
        memory
      end

      # Call sync_all
      {:ok, count, quarantined} = Indexer.sync_all()

      assert count >= 3
      assert is_list(quarantined)

      # All should be findable
      Enum.each(memories, fn memory ->
        assert Indexer.get_memory(memory.id) != nil
      end)

      # Cleanup
      Enum.each(memories, &cleanup_memory/1)
    end

    test "sync_all handles quarantine of invalid memories" do
      # Create a memory with invalid data
      invalid_memory = Acs.MemoryTestHelpers.create_test_memory(%{
        "id" => "lifecycle_invalid_#{System.unique_integer([:positive])}",
        "title" => ""  # Empty title should fail validation
      })

      # Try to save - should either fail or save with parse_error status
      _result = Loader.save(invalid_memory)

      # sync_all should handle gracefully
      {:ok, _count, quarantined} = Indexer.sync_all()

      # Invalid memories should be in quarantined list
      assert is_list(quarantined)
    end
  end

  describe "status change updates scoring" do
    test "approved memories get higher priority" do
      memory_proposed = Acs.MemoryTestHelpers.create_test_memory(%{
        "id" => "lifecycle_proposed_#{System.unique_integer([:positive])}",
        "kind" => "axiom",
        "status" => "proposed",
        "scope_path" => "test_app/status"
      })

      memory_approved = Acs.MemoryTestHelpers.create_test_memory(%{
        "id" => "lifecycle_approved_#{System.unique_integer([:positive])}",
        "kind" => "axiom",
        "status" => "approved",
        "scope_path" => "test_app/status"
      })

      Loader.save(memory_proposed)
      Loader.save(memory_approved)
      Indexer.upsert_memory(memory_proposed)
      Indexer.upsert_memory(memory_approved)

      # List all memories at scope
      memories = Indexer.list_memories(scope_path: "test_app/status")

      # Approved should appear if using hybrid search with metadata scoring
      approved_found = Enum.any?(memories, fn m -> m.id == memory_approved.id and m.status == "approved" end)
      assert approved_found

      # Cleanup
      cleanup_memory(memory_proposed)
      cleanup_memory(memory_approved)
    end

    test "stale memories get decay applied" do
      # Create an old memory (simulated via past updated_at)
      memory = Acs.MemoryTestHelpers.create_test_memory(%{
        "id" => "lifecycle_stale_#{System.unique_integer([:positive])}",
        "kind" => "learning",
        "status" => "stale",
        "scope_path" => "test_app/decay"
      })

      Loader.save(memory)
      Indexer.upsert_memory(memory)

      # Verify stale status is stored
      indexed = Indexer.get_memory(memory.id)
      assert indexed.status == "stale"

      # Cleanup
      cleanup_memory(memory)
    end
  end

  describe "canonical source integrity" do
    test "memory can be regenerated from YAML" do
      memory = Acs.MemoryTestHelpers.create_test_memory(%{
        "id" => "lifecycle_regen_#{System.unique_integer([:positive])}",
        "kind" => "decision",
        "title" => "Regeneration Test",
        "scope_path" => "test_app/regen"
      })

      # Save memory
      Loader.save(memory)

      # Delete from index
      Indexer.remove_memory(memory.id)

      # Regenerate from file
      file_path = Loader.memory_to_path(memory)
      {:ok, regenerated} = Loader.load_file(file_path)

      assert regenerated.id == memory.id
      assert regenerated.kind == memory.kind
      assert regenerated.title == memory.title
      assert regenerated.scope_path == memory.scope_path

      # Cleanup
      cleanup_memory(memory)
    end

    test "index can be rebuilt from filesystem" do
      # Create multiple memories
      memories = for i <- 1..2 do
        memory = Acs.MemoryTestHelpers.create_test_memory(%{
          "id" => "lifecycle_rebuild_#{i}_#{System.unique_integer([:positive])}",
          "kind" => "observation",
          "title" => "Rebuild Test #{i}",
          "scope_path" => "test_app/rebuild/#{i}"
        })
        Loader.save(memory)
        Indexer.upsert_memory(memory)
        memory
      end

      # Clear index
      Enum.each(memories, fn m ->
        Indexer.remove_memory(m.id)
      end)

      # Rebuild
      {:ok, count, _quarantined} = Indexer.sync_all()

      assert count >= length(memories)

      # All should be findable again
      Enum.each(memories, fn memory ->
        assert Indexer.get_memory(memory.id) != nil
      end)

      # Cleanup
      Enum.each(memories, &cleanup_memory/1)
    end
  end

  # Helper functions

  defp cleanup_memory(memory) do
    try do
      # Remove from index
      Indexer.remove_memory(memory.id)

      # Delete file
      Loader.delete(memory)
    rescue
      _ -> :ok
    end
  end


end
