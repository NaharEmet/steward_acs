defmodule Acs.Artifacts.ImporterTest do
  use Acs.DataCase, async: false

  alias Acs.Artifacts.{Importer, Ledger}
  alias Acs.Orgs.Organization

  setup do
    root =
      Path.join(System.tmp_dir!(), "acs-artifact-import-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf!(root) end)

    %{root: root}
  end

  test "fails closed when the vault source is missing", %{root: root} do
    assert {:error, {:artifact_source_not_found, _}} =
             Importer.import(root: Path.join(root, "missing"))
  end

  test "imports skill, spec, and tool fixtures while skipping prompts", %{root: root} do
    org = create_org("artifact-import")
    fixture = write_fixture(root, org.slug)

    assert {:ok, %{imported: 3, skipped: 0, organizations: organizations}} =
             Importer.import(root: root)

    assert organizations == [org.slug]
    assert length(Ledger.history("Imported Skill", :skill, org.slug)) == 1
    assert length(Ledger.history("imported_app/imported_spec", :spec, org.slug)) == 1
    assert length(Ledger.history("imported_tools/lookup", :tool, org.slug)) == 1
    assert File.regular?(fixture.prompt)
  end

  test "skips unchanged artifacts when the importer is rerun", %{root: root} do
    org = create_org("artifact-idempotent")
    write_fixture(root, org.slug)

    assert {:ok, %{imported: 3, skipped: 0}} = Importer.import(root: root)

    assert {:ok, %{imported: 0, skipped: 3, organizations: organizations}} =
             Importer.import(root: root)

    assert organizations == [org.slug]
  end

  test "returns a conflict when an imported source changes after initial import", %{root: root} do
    org = create_org("artifact-conflict")
    fixture = write_fixture(root, org.slug)

    assert {:ok, %{imported: 3}} = Importer.import(root: root)
    File.write!(fixture.skill, skill_file("Changed source content."))

    assert {:error,
            {:conflict, %{organization: organization, kind: :skill, public_id: public_id}}} =
             Importer.import(root: root)

    assert organization == org.slug
    assert public_id == "Imported Skill"
  end

  defp write_fixture(root, slug) do
    org_root = Path.join([root, "orgs", slug])
    skill = Path.join([org_root, "skills", "imported-skill.md"])
    spec = Path.join([org_root, "specs", "imported_app", "imported_spec.yaml"])
    tool = Path.join([org_root, "acstools", "imported-tools.yaml"])
    prompt = Path.join([org_root, "prompts", "skills", "instructions.md"])

    for path <- [skill, spec, tool, prompt], do: File.mkdir_p!(Path.dirname(path))

    File.write!(skill, skill_file("Imported skill content."))

    File.write!(spec, """
    app: imported_app
    id: imported_spec
    title: Imported specification
    purpose: Documents imported behavior.
    invariants:
      - Imported entries remain immutable.
    workflows:
      - Import the source fixture.
    failure_modes:
      - Source fixture is malformed.
    tags:
      - import
    """)

    File.write!(tool, """
    app: imported_tools
    tools:
      - name: lookup
        description: Look up imported data.
        endpoint: /lookup
        method: POST
        input_schema:
          type: object
          properties: {}
    """)

    File.write!(prompt, "This prompt must not be imported.")
    %{skill: skill, prompt: prompt}
  end

  defp skill_file(content) do
    """
    ---
    name: Imported Skill
    description: Imported procedure
    status: proposed
    tags: [import]
    scope_paths: [tests/import]
    ---

    #{content}
    """
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
end
