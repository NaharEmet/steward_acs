defmodule Acs.Skills.StoreTest do
  use ExUnit.Case, async: false

  alias Acs.Skills.Store

  setup do
    original_path = Application.get_env(:steward_acs, :obsidian_vault_path)
    vault = Path.join(System.tmp_dir!(), "acs_skills_#{System.unique_integer([:positive])}")
    skills_dir = Path.join(vault, "skills")
    Application.put_env(:steward_acs, :obsidian_vault_path, vault)
    File.mkdir_p!(skills_dir)

    on_exit(fn ->
      if original_path do
        Application.put_env(:steward_acs, :obsidian_vault_path, original_path)
      else
        Application.delete_env(:steward_acs, :obsidian_vault_path)
      end

      File.rm_rf!(vault)
    end)

    {:ok, skills_dir: skills_dir}
  end

  test "discovers nested Markdown skills with YAML frontmatter", %{skills_dir: skills_dir} do
    path = Path.join([skills_dir, "operations", "incident-response.md"])
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    ---
    name: Incident Response
    description: Coordinate production incidents
    tags: [operations, incident]
    status: proposed
    ---

    Follow the incident response checklist.
    """)

    assert %{
             id: "operations/incident-response",
             group: "operations",
             name: "Incident Response",
             status: "proposed",
             tags: ["operations", "incident"]
           } = Store.get_skill("operations/incident-response")

    assert Enum.any?(Store.search_skills("production incidents"), fn skill ->
             skill.id == "operations/incident-response"
           end)
  end

  test "approves and rejects by changing only governance frontmatter", %{skills_dir: skills_dir} do
    path = Path.join(skills_dir, "deployment.md")

    File.write!(path, """
    ---
    name: Deployment
    description: Release safely
    tags: [deployment]
    owner:
      team: platform
      escalation: release-managers
    priority: 2
    custom_flag: true
    ---

    Keep this externally authored content unchanged.
    """)

    assert :ok = Store.update_status("deployment", "approved", "reviewer@example.com")

    assert %{status: "approved", content: "Keep this externally authored content unchanged."} =
             Store.get_skill("deployment")

    assert {:ok, approved_file} = File.read(path)
    assert approved_file =~ "approved_by: \"reviewer@example.com\""
    assert approved_file =~ "status: \"approved\""
    assert approved_file =~ "owner:\n  team: platform\n  escalation: release-managers"
    assert approved_file =~ "priority: 2"
    assert approved_file =~ "custom_flag: true"
    assert approved_file =~ "Keep this externally authored content unchanged."

    assert :ok = Store.update_status("deployment", "rejected", "reviewer@example.com")

    assert %{status: "rejected", content: "Keep this externally authored content unchanged."} =
             Store.get_skill("deployment")
  end

  test "vault skill overrides a bundled skill with the same relative path", %{
    skills_dir: skills_dir
  } do
    File.write!(Path.join(skills_dir, "deployment.md"), """
    ---
    name: Vault Deployment
    status: proposed
    ---

    Vault-specific deployment instructions.
    """)

    skills = Enum.filter(Store.all_skills(), &(&1.id == "deployment"))
    assert [%{name: "Vault Deployment"}] = skills
  end

  test "governing a bundled fallback creates a vault overlay" do
    refute File.exists?(Path.join(Store.skill_dir(), "deployment.md"))
    assert %{status: "proposed"} = Store.get_skill("deployment")

    assert :ok = Store.update_status("deployment", "approved", "reviewer@example.com")

    overlay = Path.join(Store.skill_dir(), "deployment.md")
    assert File.exists?(overlay)
    assert %{status: "approved"} = Store.get_skill("deployment")
    assert File.read!(overlay) =~ "status: \"approved\""
  end

  test "rejects invalid governance statuses" do
    assert {:error, :invalid_status} = Store.update_status("deployment", "deleted")
  end
end
