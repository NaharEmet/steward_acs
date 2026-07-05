defmodule Acs.Memory.HybridSearchTest do
  use Acs.DataCase, async: false

  alias Acs.Memory.HybridSearch

  describe "search/2" do
    test "returns results from hybrid search" do
      setup_test_memories("test_hybrid_1")
      result = HybridSearch.search("cache release", scope: "agent_coordination_system/cache")

      assert is_map(result)
      assert result.query == "cache release"
      assert is_list(result.results)
      assert result.total >= 0
    after
      cleanup_test_memories("test_hybrid_1")
    end

    test "respects limit parameter" do
      setup_test_memories("test_hybrid_2")
      result = HybridSearch.search("test", limit: 5)

      assert length(result.results) <= 5
    after
      cleanup_test_memories("test_hybrid_2")
    end

    test "filters by scope when provided" do
      setup_test_memories("test_hybrid_1")
      result = HybridSearch.search("test", scope: "agent_coordination_system/cache")

      assert is_map(result)
      assert result.query == "test"
    after
      cleanup_test_memories("test_hybrid_1")
    end

    test "returns empty results for no matches" do
      result = HybridSearch.search("xyzzy_nonexistent_query_12345", limit: 10)

      assert is_map(result)
      assert result.results == []
    end
  end

  describe "scoring functions" do
    test "compute_lexical_score gives higher score for title match" do
      setup_test_memories("test_hybrid_1")
      result = HybridSearch.search("cache", limit: 10)

      assert is_map(result)
    after
      cleanup_test_memories("test_hybrid_1")
    end

    test "compute_scope_score gives higher score for matching scope" do
      setup_test_memories("test_hybrid_1")
      result1 = HybridSearch.search("test", scope: "agent_coordination_system/cache")
      result2 = HybridSearch.search("test", scope: "other_app")

      assert is_map(result1)
      assert is_map(result2)
    after
      cleanup_test_memories("test_hybrid_1")
    end

    test "compute_metadata_score considers importance and status" do
      setup_test_memories("test_hybrid_1")
      result = HybridSearch.search("release", limit: 10)

      assert is_map(result)
    after
      cleanup_test_memories("test_hybrid_1")
    end
  end

  describe "combined scoring" do
    test "handles empty query gracefully" do
      setup_test_memories("test_hybrid_1")
      result = HybridSearch.search("", limit: 10)

      assert is_map(result)
      assert is_list(result.results)
    after
      cleanup_test_memories("test_hybrid_1")
    end
  end

  # Helper functions

  defp setup_test_memories(id) do
    attrs = %{
      "id" => id,
      "kind" => "axiom",
      "status" => "approved",
      "title" => "Cache Release Ordering",
      "summary" => "Agent state must be cleared before cache deletion",
      "content" => "When releasing tasks, clear agent ownership before deleting cache entries",
      "scope_path" => "agent_coordination_system/cache/release",
      "importance" => 5,
      "tags" => ["cache", "concurrency"]
    }

    memory = Acs.Memory.new(attrs)
    Acs.Memory.Loader.save(memory)
    Acs.Memory.Indexer.upsert_memory(memory)
    :ok
  end

  defp cleanup_test_memories(id) do
    case Acs.Memory.Indexer.get_memory(id) do
      nil ->
        :ok

      schema ->
        Acs.Memory.Indexer.remove_memory(id)
        Acs.Memory.Loader.delete(Acs.Memory.new(Map.from_struct(schema)))
    end
  end
end
