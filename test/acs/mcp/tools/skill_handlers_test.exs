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
end
