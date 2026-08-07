defmodule Acs.Memory.ImporterTest do
  use Acs.DataCase, async: false

  alias Acs.Memory.{Importer, Ledger}
  alias Acs.Orgs.Organization

  setup do
    root =
      Path.join(System.tmp_dir!(), "acs-memory-import-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf!(root) end)

    %{root: root}
  end

  test "fails closed when the vault source is missing", %{root: root} do
    assert {:error, {:memory_source_not_found, _}} =
             Importer.import(root: Path.join(root, "missing"))
  end

  test "fails closed when an org directory has no matching database organization", %{root: root} do
    org_root = Path.join([root, "orgs", "ghost-org"])
    File.mkdir_p!(Path.join(org_root, "memories"))

    assert {:error, {:unknown_organizations, ["ghost-org"]}} = Importer.import(root: root)
  end

  test "imports memory fixtures while skipping prompts and non-memory files", %{root: root} do
    org = create_org("memory-import")
    fixture = write_fixture(root, org.slug)

    assert {:ok, %{imported: 2, skipped: 0, organizations: organizations}} =
             Importer.import(root: root)

    assert organizations == [org.slug]
    assert length(Ledger.history("imported-memory-one", org.slug)) == 1
    assert length(Ledger.history("imported-memory-two", org.slug)) == 1
    assert File.regular?(fixture.prompt)
  end

  test "skips unchanged memories when the importer is rerun", %{root: root} do
    org = create_org("memory-idempotent")
    write_fixture(root, org.slug)

    assert {:ok, %{imported: 2, skipped: 0}} = Importer.import(root: root)

    assert {:ok, %{imported: 0, skipped: 2, organizations: organizations}} =
             Importer.import(root: root)

    assert organizations == [org.slug]
  end

  test "returns a conflict when an imported source changes after initial import", %{root: root} do
    org = create_org("memory-conflict")
    fixture = write_fixture(root, org.slug)

    assert {:ok, %{imported: 2}} = Importer.import(root: root)
    File.write!(fixture.memory, memory_file("imported-memory-one", "Changed source content."))

    assert {:error, {:conflict, %{organization: organization, memory_id: memory_id, file: file}}} =
             Importer.import(root: root)

    assert organization == org.slug
    assert memory_id == "imported-memory-one"
    assert file == "imported-memory-one"
  end

  test "verifies the ledger chain after a successful import", %{root: root} do
    org = create_org("memory-verify")
    write_fixture(root, org.slug)

    assert {:ok, %{imported: 2}} = Importer.import(root: root)
    assert :ok = Importer.verify()
  end

  defp write_fixture(root, slug) do
    org_root = Path.join([root, "orgs", slug])
    memory = Path.join([org_root, "memories", "imported-memory-one.yaml"])
    nested = Path.join([org_root, "memories", "nested", "imported-memory-two.yml"])
    prompt = Path.join([org_root, "prompts", "skills", "instructions.md"])

    for path <- [memory, nested, prompt], do: File.mkdir_p!(Path.dirname(path))

    File.write!(memory, memory_file("imported-memory-one", "Imported memory content."))
    File.write!(nested, memory_file("imported-memory-two", "Nested memory content."))
    File.write!(prompt, "This prompt must not be imported.")
    %{memory: memory, prompt: prompt}
  end

  defp memory_file(id, content) do
    """
    id: #{id}
    kind: learning
    status: approved
    title: Imported memory #{id}
    scope_path: tests/import
    summary: Imported fixture
    content: #{content}
    importance: 3
    tags:
      - import
    org: default
    verification:
      status: approved
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
