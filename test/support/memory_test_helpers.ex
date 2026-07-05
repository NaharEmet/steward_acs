defmodule Acs.MemoryTestHelpers do
  @moduledoc """
  Helpers for memory system tests.

  Provides utilities for creating test memories with sensible defaults,
  and cleaning up saved memory files between tests.
  """

  import ExUnit.Assertions

  alias Acs.Memory
  alias Acs.Memory.Loader

  @doc """
  Creates a test Memory struct with sensible defaults.
  Override any field with opts (keyword list or map).

  ## Examples

      memory = Acs.MemoryTestHelpers.create_test_memory()
      memory = Acs.MemoryTestHelpers.create_test_memory(%{"title" => "My Title"})
      memory = Acs.MemoryTestHelpers.create_test_memory(id: "custom_id", importance: 5)

  """
  def create_test_memory(opts \\ []) do
    opts_map =
      cond do
        is_list(opts) -> Map.new(opts)
        is_map(opts) -> opts
        true -> %{}
      end

    id = Map.get(opts_map, "id") || "test_memory_#{System.unique_integer([:positive])}"

    defaults = %{
      "id" => id,
      "kind" => "axiom",
      "status" => "proposed",
      "title" => "Test Memory #{id}",
      "summary" => "A test memory for verification purposes",
      "content" =>
        "This is the full content of the test memory. It contains enough text to verify that search indexing and content display work correctly.",
      "scope_path" => "test_app/test_component",
      "importance" => 3,
      "tags" => ["test", "verification", "memory_system"],
      "triggers" => [],
      "failure_modes" => [],
      "related_memories" => [],
      "verification" => %{"status" => "proposed", "approved_by" => nil, "approved_at" => nil},
      "revalidation" => %{"interval_days" => 30, "last_checked_at" => nil}
    }

    merged = Map.merge(defaults, opts_map)

    case Memory.new(merged) do
      {:error, changeset} ->
        raise "Failed to create test memory: #{inspect(changeset.errors)}"

      %Memory{} = memory ->
        memory
    end
  end

  @doc """
  Cleans up a memory file that was saved via Loader.save/1.
  Removes the file and any empty parent directories.
  """
  def cleanup_saved_memory(%Memory{} = memory) do
    path = Loader.memory_to_path(memory)

    if File.exists?(path) do
      File.rm!(path)
      cleanup_parent_dirs(Path.dirname(path), Loader.memory_dir())
    end

    :ok
  end

  defp cleanup_parent_dirs(dir, stop_dir) when dir == stop_dir or dir == "" or dir == "." do
    :ok
  end

  defp cleanup_parent_dirs(dir, stop_dir) do
    case File.rmdir(dir) do
      :ok -> cleanup_parent_dirs(Path.dirname(dir), stop_dir)
      {:error, _} -> :ok
    end
  end

  @doc """
  Asserts a memory struct has expected field values.
  """
  def assert_memory_fields(memory, expected) do
    Enum.each(expected, fn {field, value} ->
      actual = Map.get(memory, field)

      assert actual == value,
             "Expected memory.#{field} to be #{inspect(value)}, got #{inspect(actual)}"
    end)
  end

  @doc """
  Asserts a Schema record (from Repo/Indexer) has expected field values.
  """
  def assert_schema_fields(schema, expected) do
    Enum.each(expected, fn {field, value} ->
      actual = Map.get(schema, field)

      assert actual == value,
             "Expected schema.#{field} to be #{inspect(value)}, got #{inspect(actual)}"
    end)
  end
end
