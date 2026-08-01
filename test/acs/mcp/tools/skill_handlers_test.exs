defmodule Acs.MCP.Tools.SkillHandlersTest do
  use ExUnit.Case, async: false

  alias Acs.MCP.Tools.SkillHandlers

  setup do
    original_path = Application.get_env(:steward_acs, :obsidian_vault_path)
    vault = Path.join(System.tmp_dir!(), "acs_skill_save_#{System.unique_integer([:positive])}")
    Application.put_env(:steward_acs, :obsidian_vault_path, vault)
    File.mkdir_p!(Acs.Skills.Store.skill_dir())

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

  test "skill_save allows a decent procedure in one pass" do
    assert {:ok, %{saved: true, status: "saved", name: "deploy-hotfix"}} =
             SkillHandlers.skill_save(%{
               "name" => "deploy-hotfix",
               "description" => "Ship an urgent hotfix",
               "content" => """
               ## Steps
               1. Branch from main
               2. Open PR with test plan
               3. Merge and watch Actions cutover
               4. Smoke the health endpoint
               """
             })
  end

  test "skill_save returns needs_input for one-liner (single-pass gate)" do
    assert {:ok, %{saved: false, status: "needs_input", questions: questions}} =
             SkillHandlers.skill_save(%{
               "name" => "not-a-skill",
               "content" => "Always lock files."
             })

    assert Enum.any?(questions, &(&1["id"] == "needs_improvement"))
  end

  test "intake_confirmed bypasses quality gate" do
    assert {:ok, %{saved: true}} =
             SkillHandlers.skill_save(%{
               "name" => "tiny-ok",
               "content" => "Always lock files.",
               "intake_confirmed" => true
             })
  end

  describe "rank-gated edits (unified role management)" do
    test "member cannot edit an existing skill at or above own rank" do
      # Stamped as rank 1 by an admin (admin can edit anything).
      assert {:ok, %{saved: true}} =
               SkillHandlers.skill_save(%{
                 "name" => "ranked-proc",
                 "content" => "## Steps\n1. Do the thing\n2. Verify\n",
                 "intake_confirmed" => true,
                 "_auth_role" => "admin",
                 "_auth_authority_sort_order" => 1
               })

      # Same-rank member tries to edit -> denied.
      assert {:error, msg} =
               SkillHandlers.skill_save(%{
                 "name" => "ranked-proc",
                 "content" => "## Steps\n1. Changed\n",
                 "intake_confirmed" => true,
                 "_auth_role" => "member",
                 "_auth_authority_sort_order" => 1
               })

      assert msg =~ "Access denied"
    end

    test "member can edit a skill strictly below own rank" do
      assert {:ok, %{saved: true}} =
               SkillHandlers.skill_save(%{
                 "name" => "low-rank-proc",
                 "content" => "## Steps\n1. Do it\n2. Check\n",
                 "intake_confirmed" => true,
                 "_auth_role" => "admin",
                 "_auth_authority_sort_order" => 5
               })

      # Member at rank 2 can edit rank-5 content (strictly below).
      assert {:ok, %{saved: true}} =
               SkillHandlers.skill_save(%{
                 "name" => "low-rank-proc",
                 "content" => "## Steps\n1. Done\n2. Verify\n",
                 "intake_confirmed" => true,
                 "_auth_role" => "member",
                 "_auth_authority_sort_order" => 2
               })
    end

    test "unranked skill is editable by a ranked member" do
      assert {:ok, %{saved: true}} =
               SkillHandlers.skill_save(%{
                 "name" => "unranked-proc",
                 "content" => "## Steps\n1. Do\n2. Verify\n",
                 "intake_confirmed" => true
               })

      assert {:ok, %{saved: true}} =
               SkillHandlers.skill_save(%{
                 "name" => "unranked-proc",
                 "content" => "## Steps\n1. Updated\n2. Verify\n",
                 "intake_confirmed" => true,
                 "_auth_role" => "member",
                 "_auth_authority_sort_order" => 2
               })
    end
  end
end
