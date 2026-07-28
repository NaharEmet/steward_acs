defmodule Acs.Memory.AuditorAutoApproveTest do
  @moduledoc "LLM approve/reject must change status (not park as needs-human-review)."
  use Acs.DataCase, async: false

  alias Acs.Memory.Indexer
  alias Acs.Memory.Schema
  alias Acs.Repo

  test "Indexer.update_status to approved is org-scoped for tenant storage ids" do
    org = "safetyconnect"
    public_id = "auto_approve_mem"
    storage_id = Indexer.storage_id(org, public_id)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert!(%Schema{
      id: storage_id,
      org: org,
      kind: "learning",
      title: "Should auto approve",
      content: "Substantive content that the auditor would accept as a durable learning.",
      scope_path: "crm/icp",
      status: "proposed",
      created_at: now,
      updated_at: now
    })

    assert {:ok, schema} = Indexer.update_status(public_id, "approved", org)
    assert schema.status == "approved"
    assert Repo.get!(Schema, storage_id).status == "approved"
  end
end
