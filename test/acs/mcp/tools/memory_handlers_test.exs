defmodule Acs.MCP.Tools.MemoryHandlersTest do
  use Acs.DataCase, async: false

  alias Acs.MCP.Tools.MemoryHandlers
  alias Acs.Memory.SubjectIdentity

  describe "generate_guidance_packet/1" do
    test "rejects invalid mode values" do
      assert {:error, msg} =
               MemoryHandlers.generate_guidance_packet(%{
                 "scope_path" => "test/module",
                 "mode" => "invalid"
               })

      assert msg =~ "Invalid mode"
    end
  end

  describe "SubjectIdentity.distinct_subject?/2" do
    test "returns true when both sides name different subjects" do
      new = ["about-type:person", "about-name:Pang Yee Ean", "scope:gmc/bhutan"]
      existing = ["about-type:person", "about-name:Lee Seow Hiang"]

      assert SubjectIdentity.distinct_subject?(new, existing)
    end

    test "returns false when both sides name the same subject" do
      new = ["about-name:Pang Yee Ean", "about-type:person"]
      existing = ["about-name:Pang Yee Ean", "about-type:person"]

      refute SubjectIdentity.distinct_subject?(new, existing)
    end

    test "returns false when a side lacks a subject (fallback to similarity)" do
      refute SubjectIdentity.distinct_subject?(["about-name:Pang Yee Ean"], ["just-a-tag"])
    end

    test "reads about tags from a schema row's tags_json" do
      new = ["about-name:Pang Yee Ean", "about-type:person"]
      row = %{tags_json: Jason.encode!(["about-name:Pang Yee Ean", "about-type:person"])}

      refute SubjectIdentity.distinct_subject?(new, row)

      other_row = %{tags_json: Jason.encode!(["about-name:Lee Seow Hiang"])}
      assert SubjectIdentity.distinct_subject?(new, other_row)
    end

    test "treats malformed tags_json as having no subject" do
      new = ["about-name:Pang Yee Ean"]
      row = %{tags_json: "not-json"}

      refute SubjectIdentity.distinct_subject?(new, row)
    end
  end

  describe "query_memories/1 include_team_project" do
    defp save_query_test(args) do
      assert {:ok, %{id: id}} = MemoryHandlers.save_memory(args)
      id
    end

    defp query_test_creator_args(extra) do
      Map.merge(
        %{
          "kind" => "learning",
          "content" => "Test content for include_team_project",
          "scope_path" => "test/scope",
          "visibility" => "org",
          "intake_confirmed" => true,
          "_auth_agent_id" => "alice@acme.com",
          "_auth_role" => "collaborator",
          "_auth_authority_level" => "standard",
          "_auth_authority_sort_order" => 3
        },
        extra
      )
    end

    test "list mode omits team/project by default" do
      unique = System.unique_integer([:positive])
      title = "No team project default #{unique}"
      scope = "test/scope/team-default-#{unique}"

      id =
        save_query_test(
          query_test_creator_args(%{
            "title" => title,
            "scope_path" => scope,
            "team" => "some-team",
            "project" => "some-project"
          })
        )

      assert {:ok, %{memories: memories}} =
               MemoryHandlers.query_memories(%{
                 "scope_path" => scope,
                 "status" => "all"
               })

      result = Enum.find(memories, &(&1.id == id))
      assert result
      refute Map.has_key?(result, :team)
      refute Map.has_key?(result, :project)
    end

    test "list mode includes team/project when include_team_project is true" do
      unique = System.unique_integer([:positive])
      title = "With team project #{unique}"
      scope = "test/scope/team-include-#{unique}"

      id =
        save_query_test(
          query_test_creator_args(%{
            "title" => title,
            "scope_path" => scope,
            "team" => "some-team",
            "project" => "some-project"
          })
        )

      assert {:ok, %{memories: memories}} =
               MemoryHandlers.query_memories(%{
                 "scope_path" => scope,
                 "status" => "all",
                 "include_team_project" => true
               })

      result = Enum.find(memories, &(&1.id == id))
      assert result
      assert result.team == "some-team"
      assert result.project == "some-project"
    end

    test "query mode omits team/project by default" do
      unique = System.unique_integer([:positive])
      title = "Query no team #{unique}"

      save_query_test(
        query_test_creator_args(%{
          "title" => title,
          "content" => "Unique searchable content #{unique}",
          "team" => "query-team",
          "project" => "query-project"
        })
      )

      assert {:ok, %{memories: memories}} =
               MemoryHandlers.query_memories(%{
                 "query" => title,
                 "status" => "all"
               })

      result = Enum.find(memories, &(&1.title == title))
      assert result
      refute Map.has_key?(result, :team)
      refute Map.has_key?(result, :project)
    end

    test "query mode includes team/project when include_team_project is true" do
      unique = System.unique_integer([:positive])
      title = "Query with team #{unique}"

      save_query_test(
        query_test_creator_args(%{
          "title" => title,
          "content" => "Unique searchable content #{unique}",
          "team" => "query-team",
          "project" => "query-project"
        })
      )

      assert {:ok, %{memories: memories}} =
               MemoryHandlers.query_memories(%{
                 "query" => title,
                 "status" => "all",
                 "include_team_project" => true
               })

      result = Enum.find(memories, &(&1.title == title))
      assert result
      assert result.team == "query-team"
      assert result.project == "query-project"
    end
  end
end
