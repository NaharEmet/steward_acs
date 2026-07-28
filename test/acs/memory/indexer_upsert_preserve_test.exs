defmodule Acs.Memory.IndexerUpsertPreserveTest do
  @moduledoc "Vault re-sync must not wipe auditor_flags or reset created_at."
  use Acs.DataCase, async: false

  alias Acs.Memory.Indexer
  alias Acs.Memory.Schema
  alias Acs.Repo

  test "upsert_memory preserves auditor_flags and created_at on conflict" do
    # Non-default org so storage_id is org-prefixed (matches multi-tenant prod).
    org = "safetyconnect"
    public_id = "preserve_flags_mem"
    storage_id = Indexer.storage_id(org, public_id)

    created =
      DateTime.utc_now()
      |> DateTime.add(-3600, :second)
      |> DateTime.truncate(:second)

    flags = ~s({"audited_at":"2026-07-28T12:00:00Z","audit_verdict":"approve"})

    Repo.insert!(%Schema{
      id: storage_id,
      org: org,
      kind: "learning",
      title: "Preserve flags title",
      content: "Body long enough for a memory that should keep auditor state across vault sync.",
      scope_path: "test/preserve",
      status: "proposed",
      auditor_flags: flags,
      created_at: created,
      updated_at: created
    })

    memory = %Acs.Memory{
      id: public_id,
      org: org,
      kind: "learning",
      status: "proposed",
      title: "Preserve flags title (updated)",
      summary: nil,
      content: "Body long enough for a memory that should keep auditor state across vault sync.",
      scope_path: "test/preserve",
      importance: 3,
      tags: [],
      triggers: [],
      failure_modes: [],
      related_memories: [],
      verification: %{"status" => "proposed"},
      revalidation: %{"interval_days" => 30},
      created_by: %{"type" => "agent", "id" => "test"},
      audience: nil,
      team: nil,
      project: nil,
      visibility: "org",
      created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    assert {:ok, _} = Indexer.upsert_memory(memory, broadcast: false)

    row = Repo.get!(Schema, storage_id)
    assert row.title == "Preserve flags title (updated)"
    assert row.auditor_flags == flags
    assert DateTime.compare(row.created_at, created) == :eq
  end
end
