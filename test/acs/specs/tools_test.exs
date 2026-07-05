defmodule Acs.Specs.ToolsTest do
  use ExUnit.Case, async: false

  setup do
    tmp_specs =
      Path.expand("../../tmp/tools_#{System.unique_integer([:positive])}", __DIR__)

    File.mkdir_p!(tmp_specs)
    orig_env = System.get_env("SPECS_PATH")
    System.put_env("SPECS_PATH", tmp_specs)

    on_exit(fn ->
      if orig_env,
        do: System.put_env("SPECS_PATH", orig_env),
        else: System.delete_env("SPECS_PATH")

      File.rm_rf!(tmp_specs)
    end)

    :ok
  end

  defp propose_spec(overrides \\ []) do
    args =
      Map.merge(
        %{
          "app" => "test",
          "path" => "my/module",
          "title" => "Memory Loader Module",
          "purpose" => "Handles loading and parsing of memory YAML files for the ACS system",
          "invariants" => [
            "Must handle malformed YAML gracefully",
            "Must preserve existing specs"
          ],
          "workflows" => [
            "Load file from disk path",
            "Parse YAML content structure",
            "Validate and store spec"
          ],
          "failure_modes" => [
            "YAML parse error prevents loading",
            "Storage write failure causes data loss"
          ]
        },
        Map.new(overrides)
      )

    Acs.Specs.Tools.call_tool("specs_propose", args)
  end

  describe "specs_get" do
    test "returns entry for existing spec" do
      propose_spec()

      assert {:ok, entry} =
               Acs.Specs.Tools.call_tool("specs_get", %{
                 "app" => "test",
                 "path" => "my/module"
               })

      assert entry["app"] == "test"
      assert entry["id"] == "my/module"
      assert entry["status"] == "proposed"
    end

    test "returns nil for non-existent spec" do
      assert {:ok, nil} =
               Acs.Specs.Tools.call_tool("specs_get", %{
                 "app" => "test",
                 "path" => "nonexistent"
               })
    end

    test "returns error for missing params" do
      assert {:error, _} = Acs.Specs.Tools.call_tool("specs_get", %{})
    end
  end

  describe "query_specs (search)" do
    test "finds matching specs" do
      propose_spec(%{
        "purpose" =>
          "Special search target module that indexes specs for full-text retrieval in ACS"
      })

      assert {:ok, %{specs: results}} =
               Acs.Specs.Tools.call_tool("query_specs", %{"query" => "Special search target"})

      assert results != []

      result_purposes = Enum.map(results, & &1["purpose"])
      assert Enum.any?(result_purposes, &String.contains?(&1, "Special search target"))
    end

    test "returns empty for no matches" do
      propose_spec()

      assert {:ok, %{specs: [], count: 0}} =
               Acs.Specs.Tools.call_tool("query_specs", %{
                 "query" => "xyznonexistent9876"
               })
    end

    test "filters by status" do
      propose_spec(%{
        "title" => "Status Module Test",
        "purpose" => "Test purpose for status filter A"
      })

      propose_spec(%{
        "title" => "Status Module Test2",
        "app" => "test",
        "path" => "my/other_module",
        "purpose" => "Test purpose for status filter B"
      })

      Acs.Specs.Tools.call_tool("specs_approve", %{
        "app" => "test",
        "path" => "my/module",
        "reviewer" => "tester"
      })

      assert {:ok, %{specs: results}} =
               Acs.Specs.Tools.call_tool("query_specs", %{
                 "query" => "purpose",
                 "status" => "approved"
               })

      assert results != []
      assert Enum.all?(results, &(&1["status"] == "approved"))
    end
  end

  describe "specs_propose" do
    test "creates a new spec" do
      assert {:ok, entry} = propose_spec()
      assert entry["status"] == "proposed"
      assert entry["app"] == "test"
      assert entry["id"] == "my/module"
      assert entry["spec_hash"] != nil
    end

    test "updates an existing spec" do
      propose_spec()

      assert {:ok, entry} = propose_spec(%{"purpose" => "Updated purpose for testing module"})
      assert entry["status"] == "proposed"
      assert entry["purpose"] == "Updated purpose for testing module"
    end

    test "returns error for missing required params" do
      assert {:error, _} = Acs.Specs.Tools.call_tool("specs_propose", %{})
    end
  end

  describe "specs_approve" do
    test "approves a proposed spec" do
      propose_spec()

      assert {:ok, entry} =
               Acs.Specs.Tools.call_tool("specs_approve", %{
                 "app" => "test",
                 "path" => "my/module",
                 "reviewer" => "Nahar"
               })

      assert entry["status"] == "approved"
      assert entry["approved_by"] == "Nahar"
      assert entry["spec_hash"] != nil
    end

    test "returns error for non-existent spec" do
      assert {:error, _} =
               Acs.Specs.Tools.call_tool("specs_approve", %{
                 "app" => "test",
                 "path" => "nonexistent",
                 "reviewer" => "tester"
               })
    end

    test "returns error for missing params" do
      assert {:error, _} = Acs.Specs.Tools.call_tool("specs_approve", %{})
    end
  end

  describe "specs_reject" do
    test "rejects a proposed spec back to under_review" do
      propose_spec()

      assert {:ok, entry} =
               Acs.Specs.Tools.call_tool("specs_reject", %{
                 "app" => "test",
                 "path" => "my/module"
               })

      assert entry["status"] == "under_review"
    end

    test "returns error for non-existent spec" do
      assert {:error, _} =
               Acs.Specs.Tools.call_tool("specs_reject", %{
                 "app" => "test",
                 "path" => "nonexistent"
               })
    end
  end

  describe "query_specs (list)" do
    test "lists all specs" do
      propose_spec(%{"path" => "mod_a", "title" => "First Module Spec"})
      propose_spec(%{"path" => "mod_b", "title" => "Second Module Spec", "app" => "other"})

      assert {:ok, %{specs: specs, count: count}} =
               Acs.Specs.Tools.call_tool("query_specs", %{})

      assert count >= 2
      assert length(specs) >= 2
    end

    test "filters by app" do
      propose_spec(%{"path" => "mod_a", "title" => "First Module Spec"})
      propose_spec(%{"path" => "mod_b", "title" => "Second Module Spec", "app" => "other"})

      assert {:ok, %{specs: specs}} =
               Acs.Specs.Tools.call_tool("query_specs", %{"app" => "other"})

      assert Enum.all?(specs, &(&1.app == "other"))
    end

    test "filters by status" do
      propose_spec()

      assert {:ok, %{specs: specs}} =
               Acs.Specs.Tools.call_tool("query_specs", %{"status" => "proposed"})

      assert Enum.all?(specs, &(&1.status == "proposed"))
    end
  end

  describe "query_specs (find undocumented)" do
    test "returns undocumented modules result" do
      assert {:ok, result} =
               Acs.Specs.Tools.call_tool("query_specs", %{"undocumented" => true})

      assert is_map(result)
      assert Map.has_key?(result, :undocumented)
      assert Map.has_key?(result, :count)
      assert is_integer(result.count)
      assert is_list(result.undocumented)
    end
  end

  describe "ABAC enforcement" do
    test "collaborator cannot read team-scoped spec" do
      propose_spec(%{
        "visibility" => "team",
        "team" => "platform",
        "path" => "scoped/module"
      })

      auth = %{
        "_auth_role" => "collaborator",
        "_auth_allowed_teams" => ["sales"]
      }

      assert {:ok, nil} =
               Acs.Specs.Tools.call_tool(
                 "specs_get",
                 %{
                   "app" => "test",
                   "path" => "scoped/module"
                 }
                 |> Map.merge(auth)
               )
    end

    test "collaborator with matching team can read team-scoped spec" do
      propose_spec(%{
        "visibility" => "team",
        "team" => "platform",
        "path" => "scoped/readable"
      })

      auth = %{
        "_auth_role" => "collaborator",
        "_auth_allowed_teams" => ["platform"]
      }

      assert {:ok, entry} =
               Acs.Specs.Tools.call_tool(
                 "specs_get",
                 %{
                   "app" => "test",
                   "path" => "scoped/readable"
                 }
                 |> Map.merge(auth)
               )

      assert entry["team"] == "platform"
    end

    test "collaborator cannot propose team-scoped spec for another team" do
      auth = %{
        "_auth_role" => "collaborator",
        "_auth_allowed_teams" => ["platform"]
      }

      assert {:error, reason} =
               Acs.Specs.Tools.call_tool(
                 "specs_propose",
                 Map.merge(
                   %{
                     "app" => "test",
                     "path" => "scoped/forbidden",
                     "title" => "Forbidden Spec",
                     "purpose" => "Should not be writable by this collaborator",
                     "invariants" => ["one"],
                     "workflows" => ["one"],
                     "failure_modes" => ["one"],
                     "visibility" => "team",
                     "team" => "sales"
                   },
                   auth
                 )
               )

      assert reason =~ "Not authorized"
    end
  end

  describe "call_tool/2 with unknown tool" do
    test "returns error for unknown tool" do
      assert {:error, _} = Acs.Specs.Tools.call_tool("specs_unknown", %{})
    end
  end

  describe "specs_propose -> approve -> get end-to-end" do
    test "end-to-end propose, approve, and get" do
      assert {:ok, proposed} =
               Acs.Specs.Tools.call_tool("specs_propose", %{
                 "app" => "e2e",
                 "path" => "full/flow",
                 "title" => "Full End To End Flow",
                 "purpose" => "Testing the complete propose to approve workflow",
                 "invariants" => ["Must complete the full lifecycle", "Must preserve state"],
                 "workflows" => [
                   "Propose the spec entry",
                   "Approve the spec entry",
                   "Get the approved spec entry"
                 ],
                 "failure_modes" => [
                   "Validation error prevents proposal",
                   "Approval fails silently"
                 ]
               })

      assert proposed["status"] == "proposed"

      assert {:ok, approved} =
               Acs.Specs.Tools.call_tool("specs_approve", %{
                 "app" => "e2e",
                 "path" => "full/flow",
                 "reviewer" => "Nahar"
               })

      assert approved["status"] == "approved"

      assert {:ok, fetched} =
               Acs.Specs.Tools.call_tool("specs_get", %{
                 "app" => "e2e",
                 "path" => "full/flow"
               })

      assert fetched["status"] == "approved"
      assert fetched["purpose"] == "Testing the complete propose to approve workflow"
    end
  end

  describe "specs_propose with full data" do
    test "creates spec with all optional fields" do
      assert {:ok, entry} =
               Acs.Specs.Tools.call_tool("specs_propose", %{
                 "app" => "test",
                 "path" => "full/spec",
                 "title" => "Full Spec Entry",
                 "purpose" => "Testing all optional fields in the spec structure",
                 "invariants" => ["Must be fast execution", "Must be safe operation"],
                 "workflows" => ["Initialize spec properly", "Populate all fields correctly"],
                 "failure_modes" => [
                   "Field validation fails completely",
                   "Storage timeout occurs suddenly"
                 ],
                 "constraints" => ["No recursion allowed"],
                 "tags" => ["full", "test"],
                 "verification_status" => "proposed"
               })

      assert entry["invariants"] == ["Must be fast execution", "Must be safe operation"]
      assert entry["workflows"] == ["Initialize spec properly", "Populate all fields correctly"]

      assert entry["failure_modes"] == [
               "Field validation fails completely",
               "Storage timeout occurs suddenly"
             ]

      assert entry["constraints"] == ["No recursion allowed"]
      assert entry["tags"] == ["full", "test"]
      assert entry["verification_status"] == "proposed"
    end
  end
end
