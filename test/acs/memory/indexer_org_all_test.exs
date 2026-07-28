defmodule Acs.Memory.IndexerOrgAllTest do
  @moduledoc "Regression: auditor must see proposed memories across orgs."
  use Acs.DataCase, async: false

  alias Acs.Memory.Indexer
  alias Acs.Memory.Schema
  alias Acs.Repo

  test "list_memories org: :all returns proposed rows from every org" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Enum.each(
      [
        {"default", "default:audit_all_a"},
        {"safetyconnect", "safetyconnect:audit_all_b"}
      ],
      fn {org, id} ->
        Repo.insert!(%Schema{
          id: id,
          org: org,
          kind: "learning",
          title: "Cross-org audit #{org}",
          content: "Enough content for audit pipeline regression coverage here.",
          scope_path: "test/auditor",
          status: "proposed",
          created_at: now,
          updated_at: now
        })
      end
    )

    ids =
      Indexer.list_memories(status: "proposed", org: :all, limit: 50)
      |> Enum.map(& &1.id)
      |> MapSet.new()

    assert "default:audit_all_a" in ids
    assert "safetyconnect:audit_all_b" in ids
  end
end
