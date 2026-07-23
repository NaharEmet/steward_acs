defmodule Acs.Specs.LoaderTest do
  use ExUnit.Case, async: false

  alias Acs.Specs.Entry
  alias Acs.Specs.Loader

  setup do
    tmp_specs =
      Path.expand("../../tmp/specs_#{System.unique_integer([:positive])}", __DIR__)

    File.mkdir_p!(tmp_specs)

    orig_env = System.get_env("SPECS_PATH")
    System.put_env("SPECS_PATH", tmp_specs)

    on_exit(fn ->
      if orig_env,
        do: System.put_env("SPECS_PATH", orig_env),
        else: System.delete_env("SPECS_PATH")

      File.rm_rf!(tmp_specs)
    end)

    {:ok, tmp_specs: tmp_specs}
  end

  defp create_test_entry(opts \\ []) do
    opts_map =
      opts
      |> Map.new()
      |> Map.new(fn {k, v} -> {to_string(k), v} end)

    defaults = %{
      "app" => "test_app",
      "id" => "my_test_module",
      "title" => "Core Business Logic Testing",
      "purpose" => "A test module for unit testing",
      "invariants" => ["Must be deterministic at runtime"],
      "workflows" => ["Processes primary user workflow"],
      "failure_modes" => ["Primary failure mode scenario"],
      "tags" => ["test"]
    }

    Entry.from_map(Map.merge(defaults, opts_map))
  end

  describe "specs_path/0" do
    test "returns the path from env var" do
      path = Loader.specs_path()
      assert String.contains?(path, "specs_")
    end
  end

  describe "module_to_path/1" do
    test "converts module atom to path" do
      assert Loader.module_to_path(MyApp.Engine.Orchestrator) == "my_app/engine/orchestrator"
    end

    test "handles single-segment modules" do
      assert Loader.module_to_path(MyApp.Core) == "my_app/core"
    end
  end

  describe "save/1 and load/2" do
    test "saves and loads a spec" do
      entry = create_test_entry()
      assert :ok = Loader.save(entry)
      assert {:ok, loaded} = Loader.load("test_app", "my_test_module")
      assert loaded.purpose == "A test module for unit testing"
      assert loaded.app == "test_app"
      assert loaded.id == "my_test_module"
    end

    test "load returns :not_found for missing spec" do
      assert {:error, :not_found} = Loader.load("test_app", "nonexistent")
    end

    test "save returns error for invalid entry" do
      entry = create_test_entry(app: "", id: "")
      assert {:error, error_msg} = Loader.save(entry)
      assert String.contains?(error_msg, "Validation failed")
      assert String.contains?(error_msg, "app is required")
      assert String.contains?(error_msg, "id is required")
    end

    test "save creates nested directories" do
      entry = create_test_entry(id: "deeply/nested/module", app: "myapp")
      assert :ok = Loader.save(entry)
      assert {:ok, loaded} = Loader.load("myapp", "deeply/nested/module")
      assert loaded.id == "deeply/nested/module"
    end

    test "round-trip preserves all fields" do
      refs = [%{"type" => "module", "target" => "other/mod", "description" => "calls"}]

      entry =
        create_test_entry(%{
          "title" => "Full Entry Comprehensive",
          "purpose" => "This is the original purpose for testing",
          "invariants" => ["First invariant must hold true", "Second invariant always applies"],
          "workflows" => ["Primary workflow processes data correctly"],
          "failure_modes" => ["Primary failure scenario to handle"],
          "constraints" => ["Constraint 1"],
          "tags" => ["tag1", "tag2"],
          "references" => refs,
          "verification_status" => "confirmed",
          "version" => 2,
          "parent_version" => 1
        })

      assert :ok = Loader.save(entry)
      assert {:ok, loaded} = Loader.load("test_app", "my_test_module")
      assert loaded.title == "Full Entry Comprehensive"
      assert loaded.purpose == "This is the original purpose for testing"

      assert loaded.invariants == [
               "First invariant must hold true",
               "Second invariant always applies"
             ]

      assert loaded.workflows == ["Primary workflow processes data correctly"]
      assert loaded.failure_modes == ["Primary failure scenario to handle"]
      assert loaded.constraints == ["Constraint 1"]
      assert loaded.tags == ["tag1", "tag2"]
      assert loaded.references == refs
      assert loaded.verification_status == "confirmed"
      assert loaded.version == 2
      assert loaded.parent_version == 1
    end
  end

  describe "delete/2" do
    test "deletes an existing spec" do
      entry = create_test_entry()
      Loader.save(entry)
      assert :ok = Loader.delete("test_app", "my_test_module")
      assert {:error, :not_found} = Loader.load("test_app", "my_test_module")
    end

    test "returns error for non-existent spec" do
      assert {:error, :not_found} = Loader.delete("test_app", "nonexistent")
    end
  end

  describe "list/1" do
    test "lists all specs when no app filter" do
      entry1 = create_test_entry(id: "module_a", app: "app1")
      entry2 = create_test_entry(id: "module_b", app: "app2")
      Loader.save(entry1)
      Loader.save(entry2)
      assert {:ok, specs} = Loader.list()
      assert length(specs) >= 2
    end

    test "filters by app" do
      entry1 = create_test_entry(id: "module_a", app: "app_x")
      Loader.save(entry1)
      assert {:ok, specs} = Loader.list(app: "app_x")
      assert Enum.all?(specs, &(&1.app == "app_x"))
    end

    test "rejects traversal app filters" do
      assert {:error, :invalid_app} = Loader.list(app: "../outside")
      assert {:error, :invalid_app} = Loader.load("../outside", "secret")
    end
  end

  describe "load_all/1" do
    test "loads all spec entries" do
      entry1 = create_test_entry(id: "module_a", app: "app1")
      entry2 = create_test_entry(id: "module_b", app: "app2")
      Loader.save(entry1)
      Loader.save(entry2)

      assert {:ok, entries} = Loader.load_all()
      assert length(entries) >= 2
      assert Enum.any?(entries, &(&1.id == "module_a"))
      assert Enum.any?(entries, &(&1.id == "module_b"))
    end

    test "load_all filters by app" do
      entry1 = create_test_entry(id: "module_a", app: "app_filter")
      entry2 = create_test_entry(id: "module_b", app: "other_app")
      Loader.save(entry1)
      Loader.save(entry2)

      assert {:ok, entries} = Loader.load_all(app: "app_filter")
      assert length(entries) == 1
      assert hd(entries).id == "module_a"
    end

    test "load_all returns empty list when no specs exist" do
      assert {:ok, []} = Loader.load_all()
    end
  end

  describe "find_undocumented/2" do
    test "returns modules without specs" do
      tmp_lib =
        System.tmp_dir!()
        |> Path.join("specs_lib_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join([tmp_lib, "lib", "my_app"]))

      File.write!(
        Path.join([tmp_lib, "lib", "my_app", "existing.ex"]),
        "defmodule MyApp.Existing do\nend\n"
      )

      File.write!(
        Path.join([tmp_lib, "lib", "my_app", "unknown.ex"]),
        "defmodule MyApp.Unknown do\nend\n"
      )

      entry = create_test_entry(id: "my_app/existing", app: "test_app")
      Loader.save(entry)

      result = Loader.find_undocumented(tmp_lib)
      undocumented = Enum.find(result, &(&1.path == "my_app/unknown"))

      assert undocumented != nil
      assert undocumented.module == "MyApp.Unknown"

      File.rm_rf!(tmp_lib)
    end
  end

  describe "file_path/2" do
    test "builds correct path" do
      path = Loader.file_path("my_app", "engine/orchestrator")
      assert String.ends_with?(path, "my_app/engine/orchestrator.yaml")
    end

    test "rejects path traversal in app" do
      assert_raise ArgumentError, ~r/Invalid path segment/, fn ->
        Loader.file_path("../etc", "passwd")
      end
    end

    test "rejects path traversal in path" do
      assert_raise ArgumentError, ~r/Invalid path segment/, fn ->
        Loader.file_path("my_app", "../../etc/passwd")
      end
    end

    test "rejects special characters" do
      assert_raise ArgumentError, ~r/Invalid path segment/, fn ->
        Loader.file_path("my_app", "engine/$(cat /etc/passwd)")
      end
    end
  end

  describe "load_file/1" do
    test "loads from explicit path" do
      entry = create_test_entry()
      Loader.save(entry)
      file_path = Loader.file_path("test_app", "my_test_module")
      assert {:ok, loaded} = Loader.load_file(file_path)
      assert loaded.id == "my_test_module"
    end

    test "returns error for non-existent path" do
      path = Path.join(Loader.specs_path(), "nonexistent/file.yaml")
      assert {:error, :parse_error, _} = Loader.load_file(path)
    end

    test "does not quarantine a file outside the tenant specs root", %{tmp_specs: tmp_specs} do
      outside_file = Path.join(Path.dirname(tmp_specs), "outside_spec.md")
      File.write!(outside_file, "not frontmatter")

      assert {:error, :outside_specs_root} = Loader.load_file(outside_file)
      assert File.exists?(outside_file)
      refute File.exists?(Path.join([tmp_specs, "quarantine", "outside_spec.md"]))

      File.rm!(outside_file)
    end
  end
end
