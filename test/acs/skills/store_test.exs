defmodule Acs.Skills.StoreTest do
  use ExUnit.Case, async: false

  alias Acs.Skills.Store

  setup do
    original_path = Application.get_env(:steward_acs, :obsidian_vault_path)
    vault = Path.join(System.tmp_dir!(), "acs_skills_#{System.unique_integer([:positive])}")
    Application.put_env(:steward_acs, :obsidian_vault_path, vault)

    on_exit(fn ->
      if original_path do
        Application.put_env(:steward_acs, :obsidian_vault_path, original_path)
      else
        Application.delete_env(:steward_acs, :obsidian_vault_path)
      end

      File.rm_rf!(vault)
    end)

    :ok
  end

  test "saves, searches, updates, and deletes a skill" do
    name = "incident-response-#{System.unique_integer([:positive])}"

    assert {:ok, ^name} =
             Store.save_skill(
               name,
               "Follow the incident response checklist and record every action taken.",
               ["operations", "incident"],
               "Coordinate incident response"
             )

    assert %{name: ^name, description: "Coordinate incident response"} = Store.get_skill(name)
    assert Enum.any?(Store.search_skills("incident response"), &(&1.name == name))

    assert {:ok, ^name} =
             Store.save_skill(
               name,
               "Use the updated incident response workflow.",
               ["operations"],
               "Updated guidance"
             )

    assert %{description: "Updated guidance", tags: ["operations"]} = Store.get_skill(name)
    assert Store.writable_skill?(name)
    assert :ok = Store.delete_skill(name)
    assert Store.get_skill(name) == nil
    refute Store.writable_skill?(name)
    assert {:error, :not_found} = Store.delete_skill(name)
  end

  test "round-trips YAML-sensitive scalar values safely" do
    name = "[ops]: response"
    description = "Use caution: preserve --- separators and [brackets]"

    assert {:ok, ^name} =
             Store.save_skill(
               name,
               "Detailed guidance for unusual YAML scalar values.",
               ["ops:urgent"],
               description
             )

    assert %{
             name: ^name,
             description: ^description,
             tags: ["ops:urgent"]
           } = Store.get_skill(name)
  end

  test "does not delete a fallback built-in skill from a configured vault" do
    assert Store.get_skill("deployment")
    assert {:error, :read_only} = Store.delete_skill("deployment")
    assert Store.get_skill("deployment")
  end
end
