defmodule Acs.Cognition.EntryTest do
  use ExUnit.Case, async: true

  alias Acs.Cognition.Entry

  describe "from_map/1" do
    test "sets defaults for nil fields" do
      entry = Entry.from_map(%{"app" => "test", "id" => "test/path"})
      assert entry.status == "proposed"
      assert entry.version == 1
      assert entry.parent_version == 0
      assert entry.invariants == []
      assert entry.workflows == []
      assert entry.failure_modes == []
      assert entry.constraints == []
      assert entry.tags == []
      assert entry.references == []
      assert entry.input == nil
      assert entry.output == nil
      assert entry.expected_transformation == nil
    end

    test "preserves input/output/expected_transformation" do
      entry =
        Entry.from_map(%{
          "app" => "anantha",
          "id" => "engine/orch",
          "input" => "JSON payload with org_id and message",
          "output" => "Structured intent map with context",
          "expected_transformation" => "Parses, validates, enriches with context, and routes to planner"
        })

      assert entry.input == "JSON payload with org_id and message"
      assert entry.output == "Structured intent map with context"
      assert entry.expected_transformation == "Parses, validates, enriches with context, and routes to planner"
    end

    test "preserves provided values" do
      entry =
        Entry.from_map(%{
          "app" => "anantha",
          "id" => "engine/orchestrator",
          "title" => "Orchestrator",
          "purpose" => "Manages workflows",
          "invariants" => ["Must be stateless"],
          "status" => "approved",
          "version" => 3,
          "parent_version" => 2,
          "tags" => ["core", "workflow"]
        })

      assert entry.app == "anantha"
      assert entry.id == "engine/orchestrator"
      assert entry.title == "Orchestrator"
      assert entry.purpose == "Manages workflows"
      assert entry.invariants == ["Must be stateless"]
      assert entry.status == "approved"
      assert entry.version == 3
      assert entry.parent_version == 2
      assert entry.tags == ["core", "workflow"]
    end

    test "sets created_at and updated_at to ISO 8601" do
      entry = Entry.from_map(%{"app" => "test", "id" => "test/path"})
      assert entry.created_at != nil
      assert entry.updated_at != nil
      assert String.contains?(entry.created_at, "T")
      assert String.contains?(entry.updated_at, "T")
    end
  end

  describe "to_map/1" do
    test "excludes nil and empty list fields" do
      entry = Entry.from_map(%{"app" => "test", "id" => "test/path"})
      map = Entry.to_map(entry)
      refute Map.has_key?(map, "proposed_by")
      refute Map.has_key?(map, "title")
      refute Map.has_key?(map, "purpose")
      refute Map.has_key?(map, "state_machine")
      refute Map.has_key?(map, "invariants")
      refute Map.has_key?(map, "workflows")
    end

    test "includes populated fields" do
      entry =
        Entry.from_map(%{
          "app" => "anantha",
          "id" => "engine/orch",
          "title" => "Orch",
          "purpose" => "Does stuff",
          "invariants" => ["Must be fast"],
          "proposed_by" => "Alice"
        })

      map = Entry.to_map(entry)
      assert map["app"] == "anantha"
      assert map["id"] == "engine/orch"
      assert map["title"] == "Orch"
      assert map["purpose"] == "Does stuff"
      assert map["invariants"] == ["Must be fast"]
      assert map["proposed_by"] == "Alice"
    end
  end

  describe "validate/1" do
    test "returns :ok for valid entry" do
      entry = Entry.from_map(%{"app" => "test", "id" => "valid/path", "title" => "Test Module Entry", "purpose" => "Test module purpose for validating entries with quality content", "invariants" => ["Always returns ok when content is valid"], "workflows" => ["Agent calls validate with entry data"], "failure_modes" => ["Entry may fail validation if content is too short"]})
      assert Entry.validate(entry) == :ok
    end

    test "returns error when app is missing" do
      entry = Entry.from_map(%{"id" => "path"})
      assert {:error, reasons} = Entry.validate(entry)
      assert Enum.any?(reasons, &String.contains?(&1, "app is required"))
    end

    test "returns error when id is missing" do
      entry = Entry.from_map(%{"app" => "test"})
      assert {:error, reasons} = Entry.validate(entry)
      assert Enum.any?(reasons, &String.contains?(&1, "id is required"))
    end

    test "rejects invalid status" do
      entry = Entry.from_map(%{"app" => "test", "id" => "path", "status" => "invalid_status"})
      assert {:error, reasons} = Entry.validate(entry)
      assert Enum.any?(reasons, &String.contains?(&1, "invalid status"))
    end

    test "accepts all valid statuses" do
      for status <- ~w(proposed under_review approved deprecated contradicted runtime_divergent historical rejected) do
        entry = Entry.from_map(%{"app" => "test", "id" => "path", "status" => status, "title" => "Test Module Entry", "purpose" => "Test module purpose for validating entries with quality content", "invariants" => ["Always returns ok when content is valid"], "workflows" => ["Agent calls validate with entry data"], "failure_modes" => ["Entry may fail validation if content is too short"]})
        assert Entry.validate(entry) == :ok
      end
    end

    test "rejects invalid verification_status" do
      entry =
        Entry.from_map(%{"app" => "test", "id" => "path", "verification_status" => "bogus"})

      assert {:error, reasons} = Entry.validate(entry)
      assert Enum.any?(reasons, &String.contains?(&1, "invalid verification_status"))
    end

    test "accepts all valid verification statuses" do
      for vs <- ~w(confirmed inferred proposed contested unknown) do
        entry = Entry.from_map(%{"app" => "test", "id" => "path", "verification_status" => vs, "title" => "Test Module Entry", "purpose" => "Test module purpose for validating entries with quality content", "invariants" => ["Always returns ok when content is valid"], "workflows" => ["Agent calls validate with entry data"], "failure_modes" => ["Entry may fail validation if content is too short"]})
        assert Entry.validate(entry) == :ok
      end
    end

    test "rejects references missing type" do
      entry =
        Entry.from_map(%{
          "app" => "test",
          "id" => "path",
          "references" => [%{"target" => "other/module"}]
        })

      assert {:error, reasons} = Entry.validate(entry)
      assert Enum.any?(reasons, &String.contains?(&1, "missing type"))
    end

    test "rejects references missing target" do
      entry =
        Entry.from_map(%{
          "app" => "test",
          "id" => "path",
          "references" => [%{"type" => "module"}]
        })

      assert {:error, reasons} = Entry.validate(entry)
      assert Enum.any?(reasons, &String.contains?(&1, "missing target"))
    end

    test "accepts valid references" do
      entry =
        Entry.from_map(%{
          "app" => "test",
          "id" => "path",
          "title" => "Test Module Entry",
          "purpose" => "Test module purpose for validating entries with quality content",
          "invariants" => ["Always returns ok when content is valid"],
          "workflows" => ["Agent calls validate with entry data"],
          "failure_modes" => ["Entry may fail validation if content is too short"],
          "references" => [
            %{"type" => "module", "target" => "other/module", "description" => "depends on"}
          ]
        })

      assert Entry.validate(entry) == :ok
    end

    test "rejects version < 1" do
      entry = Entry.from_map(%{"app" => "test", "id" => "path", "version" => 0})
      assert {:error, reasons} = Entry.validate(entry)
      assert Enum.any?(reasons, &String.contains?(&1, "version must be >= 1"))
    end
  end

  describe "spec_filename/2" do
    test "generates correct path" do
      assert Entry.spec_filename("anantha", "engine/orchestrator") == "anantha/engine/orchestrator.yaml"
    end

    test "handles simple names" do
      assert Entry.spec_filename("myapp", "core") == "myapp/core.yaml"
    end
  end

  describe "compute_spec_hash/1" do
    test "is deterministic for same content" do
      entry1 =
        Entry.from_map(%{
          "app" => "test",
          "id" => "path",
          "purpose" => "Do stuff",
          "invariants" => ["Must be fast"]
        })

      entry2 =
        Entry.from_map(%{
          "app" => "test",
          "id" => "path",
          "purpose" => "Do stuff",
          "invariants" => ["Must be fast"]
        })

      hash1 = Entry.compute_spec_hash(entry1)
      hash2 = Entry.compute_spec_hash(entry2)
      assert hash1 == hash2
    end

    test "produces 64-char hex string" do
      entry = Entry.from_map(%{"app" => "test", "id" => "path", "purpose" => "hello"})
      hash = Entry.compute_spec_hash(entry)
      assert String.length(hash) == 64
      assert hash =~ ~r/^[a-f0-9]{64}$/
    end

    test "changes when content changes" do
      entry1 = Entry.from_map(%{"app" => "test", "id" => "path", "purpose" => "Original purpose"})
      entry2 = Entry.from_map(%{"app" => "test", "id" => "path", "purpose" => "Changed purpose"})
      refute Entry.compute_spec_hash(entry1) == Entry.compute_spec_hash(entry2)
    end

    test "does NOT include metadata in hash" do
      entry1 =
        Entry.from_map(%{
          "app" => "test",
          "id" => "path",
          "purpose" => "same",
          "proposed_by" => "Alice"
        })

      entry2 =
        Entry.from_map(%{
          "app" => "test",
          "id" => "path",
          "purpose" => "same",
          "proposed_by" => "Bob"
        })

      assert Entry.compute_spec_hash(entry1) == Entry.compute_spec_hash(entry2)
    end
  end
end
