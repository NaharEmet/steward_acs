defmodule Acs.Memory.ToolGuidanceTest do
  use Acs.DataCase, async: false

  alias Acs.Memory.ToolGuidance
  alias Acs.Memory.Guidance

  describe "ToolGuidance.for_scope/1" do
    test "returns guidance for agent_coordination_system/tools" do
      guidance = ToolGuidance.for_scope("agent_coordination_system/tools")
      assert is_map(guidance)
      assert Map.has_key?(guidance, :critical_axioms)
      assert Map.has_key?(guidance, :warnings)
      assert Map.has_key?(guidance, :relevant_patterns)
      assert Map.has_key?(guidance, :compressed_knowledge)
    end

    test "returns guidance for all 6 known tool scopes" do
      scopes = [
        "agent_coordination_system/tools",
        "agent_coordination_system/tools/core",
        "agent_coordination_system/tools/knowledge",
        "agent_coordination_system/tools/specs",
        "agent_coordination_system/tools/diagnostic",
        "agent_coordination_system/tools/crm"
      ]

      Enum.each(scopes, fn scope ->
        guidance = ToolGuidance.for_scope(scope)
        assert is_map(guidance), "Expected map for scope: #{scope}"
        assert guidance.critical_axioms != [], "Expected axioms for scope: #{scope}"
      end)
    end

    test "returns nil for unknown scopes" do
      assert ToolGuidance.for_scope("agent_coordination_system") == nil
      assert ToolGuidance.for_scope("anything/else") == nil
      assert ToolGuidance.for_scope("") == nil
    end

    test "trims whitespace from scope path" do
      guidance = ToolGuidance.for_scope("  agent_coordination_system/tools  ")
      assert is_map(guidance)
    end
  end

  describe "ToolGuidance.known_scopes/0" do
    test "returns list of all known tool scopes" do
      scopes = ToolGuidance.known_scopes()
      assert is_list(scopes)
      assert length(scopes) == 6
      assert "agent_coordination_system/tools" in scopes
      assert "agent_coordination_system/tools/core" in scopes
      assert "agent_coordination_system/tools/knowledge" in scopes
      assert "agent_coordination_system/tools/specs" in scopes
      assert "agent_coordination_system/tools/diagnostic" in scopes
      assert "agent_coordination_system/tools/crm" in scopes
    end
  end

  describe "ToolGuidance.all_scopes_guidance/0" do
    test "returns a string" do
      assert is_binary(ToolGuidance.all_scopes_guidance())
      assert String.length(ToolGuidance.all_scopes_guidance()) > 0
    end

    test "contains reference to ACS Tool Guidance" do
      guidance = ToolGuidance.all_scopes_guidance()
      assert String.contains?(guidance, "ACS Tool Guidance")
      assert String.contains?(guidance, "for_scope/1")
      assert String.contains?(guidance, "known_scopes/0")
    end
  end

  describe "Guidance.generate/1 with tool scopes" do
    test "includes hardcoded tool axioms when scope matches" do
      packet = Guidance.generate("agent_coordination_system/tools/core")

      assert packet.critical_axioms != []
      assert packet.warnings != []
      assert packet.relevant_patterns != []
    end

    test "hardcoded items have toolguidance_ prefix IDs" do
      packet = Guidance.generate("agent_coordination_system/tools/knowledge")

      tool_ids =
        Enum.filter(packet.critical_axioms, fn a ->
          String.starts_with?(a.id, "toolguidance_")
        end)

      assert tool_ids != []
    end

    test "items have required fields" do
      packet = Guidance.generate("agent_coordination_system/tools/core")

      Enum.each(packet.critical_axioms, fn axiom ->
        assert Map.has_key?(axiom, :id)
        assert Map.has_key?(axiom, :title)
        assert Map.has_key?(axiom, :summary)
        assert Map.has_key?(axiom, :importance)
      end)

      Enum.each(packet.warnings, fn warning ->
        assert Map.has_key?(warning, :id)
        assert Map.has_key?(warning, :title)
        assert Map.has_key?(warning, :summary)
        assert Map.has_key?(warning, :importance)
      end)

      Enum.each(packet.relevant_patterns, fn pattern ->
        assert Map.has_key?(pattern, :id)
        assert Map.has_key?(pattern, :title)
        assert Map.has_key?(pattern, :summary)
        assert Map.has_key?(pattern, :importance)
      end)
    end

    test "includes standard hardcoded attributes" do
      packet = Guidance.generate("agent_coordination_system/tools/core")

      assert Map.has_key?(packet, :maintenance_instructions)
      assert Map.has_key?(packet, :tool_reference)
      assert Map.has_key?(packet, :specs_instructions)
      assert Map.has_key?(packet, :specs_mismatch_protocol)
      assert is_binary(packet.maintenance_instructions)
      assert String.length(packet.maintenance_instructions) > 0
      assert String.contains?(packet.maintenance_instructions, "set_memory_status")
      assert is_binary(packet.tool_reference)
      assert is_binary(packet.specs_instructions)
      assert is_binary(packet.specs_mismatch_protocol)
    end

    test "merges axioms from both memories and hardcoded guidance" do
      packet = Guidance.generate("agent_coordination_system/tools/specs")

      toolguidance_items =
        Enum.filter(packet.critical_axioms, fn a ->
          String.starts_with?(a.id, "toolguidance_")
        end)

      assert toolguidance_items != []
    end
  end

  describe "nil scope handling" do
    test "unknown scope returns empty arrays (no hardcoded items)" do
      packet = Guidance.generate("random/unknown/scope")

      assert packet.critical_axioms == []
      assert packet.warnings == []
      assert packet.relevant_patterns == []
      assert packet.compressed_knowledge == ""
    end

    test "unknown scope still includes standard hardcoded attributes" do
      packet = Guidance.generate("random/unknown/scope")

      assert Map.has_key?(packet, :maintenance_instructions)
      assert Map.has_key?(packet, :tool_reference)
      assert Map.has_key?(packet, :specs_instructions)
      assert Map.has_key?(packet, :specs_mismatch_protocol)
      assert is_binary(packet.maintenance_instructions)
    end
  end

  describe "each tool scope has unique content" do
    test "each scope has different critical_axioms" do
      axiom_ids =
        ToolGuidance.known_scopes()
        |> Enum.map(fn scope ->
          guidance = ToolGuidance.for_scope(scope)
          Enum.map(guidance.critical_axioms, & &1.id)
        end)
        |> List.flatten()

      assert length(axiom_ids) == length(Enum.uniq(axiom_ids)),
             "Each scope should have unique axiom IDs"
    end

    test "each scope has different compressed_knowledge content" do
      contents =
        ToolGuidance.known_scopes()
        |> Enum.map(fn scope ->
          guidance = ToolGuidance.for_scope(scope)
          guidance.compressed_knowledge
        end)

      assert length(contents) == length(Enum.uniq(contents)),
             "Each scope should have unique compressed_knowledge content"
    end
  end

  describe "Guidance.generate/2 with tier option" do
    test ":claim tier returns only high-importance items" do
      packet = Guidance.generate("agent_coordination_system/tools/core", tier: :claim)

      assert packet.tier == :claim
      assert is_list(packet.critical_axioms)
      assert is_list(packet.warnings)
      assert packet.relevant_patterns == []
      assert packet.compressed_knowledge == ""
    end

    test ":full tier returns all categories" do
      packet = Guidance.generate("agent_coordination_system/tools/core", tier: :full)

      assert packet.tier == :full
      assert packet.critical_axioms != []
      assert packet.warnings != []
      assert packet.relevant_patterns != []
      assert is_binary(packet.compressed_knowledge)
    end
  end

  describe "ToolGuidance.for_scope returns nil for non-matching scopes" do
    test "agent_coordination_system root returns nil" do
      assert ToolGuidance.for_scope("agent_coordination_system") == nil
    end

    test "arbitrary string returns nil" do
      assert ToolGuidance.for_scope("anything/else") == nil
    end

    test "empty string returns nil" do
      assert ToolGuidance.for_scope("") == nil
    end

    test "non-matching subscope returns nil" do
      assert ToolGuidance.for_scope("agent_coordination_system/tools/nonexistent") == nil
    end
  end
end
