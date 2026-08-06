defmodule Acs.Artifacts.LedgerTest do
  use Acs.DataCase, async: false

  alias Acs.Artifacts.{Commit, CompanyArtifact, Ledger, Revision, Skill}
  alias Acs.Orgs.Organization

  setup do
    previous_multi_tenant = Application.get_env(:steward_acs, :multi_tenant)
    previous_vault = Application.get_env(:steward_acs, :obsidian_vault_path)

    vault =
      Path.join(System.tmp_dir!(), "acs-artifact-ledger-#{System.unique_integer([:positive])}")

    Application.put_env(:steward_acs, :multi_tenant, true)
    Application.put_env(:steward_acs, :obsidian_vault_path, vault)

    on_exit(fn ->
      restore_env(:multi_tenant, previous_multi_tenant)
      restore_env(:obsidian_vault_path, previous_vault)
      Acs.Org.clear_request_org()
      File.rm_rf!(vault)
    end)

    %{vault: vault}
  end

  test "appends revised snapshots to an artifact's oldest-first history" do
    org = create_org("artifact-history")
    original = skill_snapshot("Release checklist", "Review the release.")

    assert {:ok, %{revision: first}} =
             Ledger.save(:skill, "Release checklist", original, org: org)

    revised = Map.put(original, "content", "Review and approve the release.")

    assert {:ok, %{revision: second}} =
             Ledger.save(:skill, "Release checklist", revised,
               org: org,
               expected_head_revision_id: first.id
             )

    assert Enum.map(Ledger.history("Release checklist", :skill, org.slug), & &1.id) == [
             first.id,
             second.id
           ]

    assert second.revision_number == 2
    assert second.parent_revision_id == first.id
    assert {:ok, ^revised} = Ledger.snapshot(second)
  end

  test "rejects a revision when the expected head is omitted" do
    org = create_org("artifact-missing-head")
    snapshot = skill_snapshot("Missing expected head", "Initial content.")

    assert {:ok, _} = Ledger.save(:skill, "Missing expected head", snapshot, org: org)

    assert {:error, :expected_head_revision_required} =
             Ledger.save(
               :skill,
               "Missing expected head",
               Map.put(snapshot, "content", "Changed."),
               org: org
             )
  end

  test "rejects a revision with a stale expected head" do
    org = create_org("artifact-stale-head")
    snapshot = skill_snapshot("Stale expected head", "Initial content.")

    assert {:ok, %{revision: first}} =
             Ledger.save(:skill, "Stale expected head", snapshot, org: org)

    assert {:ok, %{revision: second}} =
             Ledger.save(:skill, "Stale expected head", Map.put(snapshot, "content", "Current."),
               org: org,
               expected_head_revision_id: first.id
             )

    assert {:error, {:conflict, %{expected_head: expected, actual_head: actual}}} =
             Ledger.save(:skill, "Stale expected head", Map.put(snapshot, "content", "Stale."),
               org: org,
               expected_head_revision_id: first.id
             )

    assert expected == first.id
    assert actual == second.id
  end

  test "updates the skill projection to the artifact head revision" do
    org = create_org("artifact-projection")
    snapshot = skill_snapshot("Projection skill", "First content.")

    assert {:ok, %{revision: first}} = Ledger.save(:skill, "Projection skill", snapshot, org: org)

    assert {:ok, %{revision: head}} =
             Ledger.save(:skill, "Projection skill", Map.put(snapshot, "status", "approved"),
               org: org,
               expected_head_revision_id: first.id
             )

    artifact =
      Repo.get_by!(CompanyArtifact,
        organization_id: org.id,
        kind: "skill",
        public_id: "Projection skill"
      )

    projection = Repo.get_by!(Skill, organization_id: org.id, public_id: "Projection skill")

    assert artifact.head_revision_id == head.id
    assert projection.head_revision_id == head.id
    assert projection.status == "approved"
    assert projection.snapshot_json == head.snapshot_json
  end

  test "rejects projection rewrites and head rewinds outside the ledger" do
    org = create_org("artifact-projection-guard")
    snapshot = skill_snapshot("Guarded skill", "First content.")

    assert {:ok, %{revision: first}} = Ledger.save(:skill, "Guarded skill", snapshot, org: org)

    assert {:ok, %{revision: second}} =
             Ledger.save(:skill, "Guarded skill", Map.put(snapshot, "content", "Second content."),
               org: org,
               expected_head_revision_id: first.id
             )

    artifact =
      Repo.get_by!(CompanyArtifact,
        organization_id: org.id,
        kind: "skill",
        public_id: "Guarded skill"
      )

    assert {:error, _} =
             Ecto.Adapters.SQL.query(
               Repo,
               "UPDATE acs_skills SET content = 'tampered' WHERE organization_id = ? AND public_id = ?",
               [org.id, "Guarded skill"]
             )

    assert {:error, _} =
             Ecto.Adapters.SQL.query(
               Repo,
               "UPDATE company_artifacts SET head_revision_id = ? WHERE id = ?",
               [first.id, artifact.id]
             )

    assert Repo.get!(CompanyArtifact, artifact.id).head_revision_id == second.id

    assert Repo.get_by!(Skill, organization_id: org.id, public_id: "Guarded skill").content ==
             "Second content."

    assert :ok = Ledger.verify(org.slug)
  end

  test "rejects updates and deletes for immutable commits and revisions" do
    org = create_org("artifact-immutable")

    assert {:ok, %{revision: revision, commit: commit}} =
             Ledger.save(:skill, "Immutable skill", skill_snapshot("Immutable skill", "Content."),
               org: org
             )

    assert {:error, _} =
             Ecto.Adapters.SQL.query(
               Repo,
               "UPDATE artifact_commits SET message = 'changed' WHERE id = ?",
               [commit.id]
             )

    assert {:error, _} =
             Ecto.Adapters.SQL.query(Repo, "DELETE FROM artifact_revisions WHERE id = ?", [
               revision.id
             ])

    assert Repo.get!(Commit, commit.id).message == commit.message
    assert Repo.get!(Revision, revision.id).id == revision.id
  end

  test "verifies valid commit chains and projection heads" do
    org = create_org("artifact-verify")
    snapshot = skill_snapshot("Verified skill", "First content.")

    assert {:ok, %{revision: first}} = Ledger.save(:skill, "Verified skill", snapshot, org: org)

    assert {:ok, _} =
             Ledger.save(
               :skill,
               "Verified skill",
               Map.put(snapshot, "content", "Second content."),
               org: org,
               expected_head_revision_id: first.id
             )

    assert :ok = Ledger.verify(org.slug)
  end

  defp skill_snapshot(name, content) do
    %{
      "name" => name,
      "description" => "Regression-test procedure",
      "status" => "proposed",
      "tags" => ["regression"],
      "scope_paths" => ["tests/artifacts"],
      "content" => content
    }
  end

  defp create_org(suffix) do
    value = "#{suffix}-#{System.unique_integer([:positive])}"

    %Organization{}
    |> Organization.changeset(%{
      name: value,
      slug: value,
      subdomain: value,
      plan: "free",
      provisioning_status: "ready"
    })
    |> Repo.insert!()
  end

  defp restore_env(key, nil), do: Application.delete_env(:steward_acs, key)
  defp restore_env(key, value), do: Application.put_env(:steward_acs, key, value)
end
