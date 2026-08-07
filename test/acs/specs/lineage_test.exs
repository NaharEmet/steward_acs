defmodule Acs.Specs.LineageTest do
  use ExUnit.Case, async: true

  alias Acs.Specs.{Entry, Lineage}

  defp entry(id, status \\ "approved") do
    %Entry{
      app: "steward_acs",
      id: id,
      title: String.capitalize(id),
      status: status,
      references: []
    }
  end

  test "deprecates an approved entry and links both sides" do
    old = entry("old-guide")
    replacement = entry("new-guide")

    assert {:ok, deprecated, linked} = Lineage.deprecate(old, replacement)
    assert deprecated.status == "deprecated"

    assert Enum.any?(
             deprecated.references,
             &(&1["type"] == "replaced_by" and &1["target"] == "steward_acs/new-guide")
           )

    assert Enum.any?(
             linked.references,
             &(&1["type"] == "replaces" and &1["target"] == "steward_acs/old-guide")
           )
  end

  test "requires both entries to be approved" do
    assert {:error, :entry_not_approved} =
             Lineage.deprecate(entry("old-guide", "proposed"), entry("new-guide"))

    assert {:error, :replacement_not_approved} =
             Lineage.deprecate(entry("old-guide"), entry("new-guide", "proposed"))
  end

  test "does not allow an entry to replace itself" do
    assert {:error, :same_entry} = Lineage.deprecate(entry("same"), entry("same"))
  end
end
