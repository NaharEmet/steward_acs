defmodule Acs.Cognition.SearchTest do
  use ExUnit.Case, async: true

  alias Acs.Cognition.Entry
  alias Acs.Cognition.Loader
  alias Acs.Cognition.Search

  setup do
    tmp_specs =
      Path.expand("../../tmp/cognition_search_#{System.unique_integer([:positive])}", __DIR__)

    File.mkdir_p!(tmp_specs)
    orig_env = System.get_env("COGNITION_SPECS_PATH")
    System.put_env("COGNITION_SPECS_PATH", tmp_specs)

    # Create some test specs
    specs = [
      Entry.from_map(%{
        "app" => "anantha",
        "id" => "engine/orchestrator",
        "title" => "Workflow Orchestrator",
        "purpose" => "Coordinates execution of multi-step workflows across worker processes",
        "invariants" => ["Workflow definitions must be idempotent under repeated execution", "Retry logic must be configurable and bounded"],
        "workflows" => ["call_orchestrate -> validate -> execute -> complete the workflow cycle"],
        "failure_modes" => ["Worker crash during long-running workflow execution", "Timeout during validation phase of workflow"],
        "constraints" => ["Must not consume more than 1GB memory per worker instance"],
        "tags" => ["core", "workflow", "orchestration"],
        "status" => "approved"
      }),
      Entry.from_map(%{
        "app" => "anantha",
        "id" => "ant/core/ir_builder",
        "title" => "IR Builder",
        "purpose" => "Builds intermediate representations from parsed user input for compilation",
        "invariants" => ["IR must be validated before compilation passes can execute", "All IR nodes must carry source location metadata"],
        "workflows" => ["parse user input -> validate structure -> build_ir -> optimize the representation"],
        "failure_modes" => ["Invalid or malformed user input causes IR construction to fail", "Memory exhaustion during deep IR optimization"],
        "tags" => ["ant", "ir", "compilation"],
        "status" => "proposed"
      }),
      Entry.from_map(%{
        "app" => "anantha",
        "id" => "engine/worker_pool",
        "title" => "Worker Pool Manager",
        "purpose" => "Manages a configurable pool of workers for parallel task execution across cores",
        "invariants" => ["Workers must report status periodically to enable health monitoring", "Pool size must remain within configured bounds at all times"],
        "workflows" => ["acquire worker from pool -> process task -> release worker back to pool"],
        "failure_modes" => ["Worker becomes unresponsive during task processing and does not report", "Pool exhaustion leads to task queuing and increased latency"],
        "tags" => ["core", "workers", "concurrency"],
        "status" => "approved"
      })
    ]

    Enum.each(specs, &Loader.save/1)

    on_exit(fn ->
      if orig_env,
        do: System.put_env("COGNITION_SPECS_PATH", orig_env),
        else: System.delete_env("COGNITION_SPECS_PATH")

      File.rm_rf!(tmp_specs)
    end)

    :ok
  end

  describe "search/2" do
    test "finds by keyword in title" do
      assert {:ok, results} = Search.search("orchestrator")
      assert length(results) >= 1
      assert Enum.any?(results, &(&1.id == "engine/orchestrator"))
    end

    test "finds by keyword in purpose" do
      assert {:ok, results} = Search.search("intermediate representations")
      assert length(results) >= 1
      assert Enum.any?(results, &(&1.id == "ant/core/ir_builder"))
    end

    test "finds by keyword in invariants" do
      assert {:ok, results} = Search.search("idempotent")
      assert length(results) >= 1
      assert Enum.any?(results, &(&1.id == "engine/orchestrator"))
    end

    test "finds by keyword in tags" do
      assert {:ok, results} = Search.search("workers")
      assert length(results) >= 1
      assert Enum.any?(results, &(&1.id == "engine/worker_pool"))
    end

    test "finds by keyword in failure_modes" do
      assert {:ok, results} = Search.search("Worker crash")
      assert length(results) >= 1
      assert Enum.any?(results, &(&1.id == "engine/orchestrator"))
    end

    test "returns empty for no matches" do
      assert {:ok, []} = Search.search("xyznonexistent9876")
    end

    test "returns empty for nil query" do
      assert {:ok, []} = Search.search(nil)
    end

    test "returns empty for empty query" do
      assert {:ok, []} = Search.search("")
    end

    test "filters by status" do
      assert {:ok, results} = Search.search("orchestrator", status: "approved")
      assert length(results) >= 1
      assert Enum.all?(results, &(&1.status == "approved"))
    end

    test "filters by app" do
      assert {:ok, results} = Search.search("orchestrator", app: "anantha")
      assert length(results) >= 1
    end

    test "excludes results from different app" do
      assert {:ok, results} = Search.search("orchestrator", app: "nonexistent")
      assert results == []
    end

    test "search is case-insensitive" do
      assert {:ok, results} = Search.search("ORCHESTRATOR")
      assert Enum.any?(results, &(&1.id == "engine/orchestrator"))
    end
  end
end
