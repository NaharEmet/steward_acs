defmodule AcsWeb.AcsLive.PromptsLiveTest do
  use ExUnit.Case, async: false

  alias Acs.Prompts

  setup do
    tmp = Path.join(System.tmp_dir!(), "acs-prompts-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    original_vault = Application.get_env(:steward_acs, :obsidian_vault_path)
    Application.put_env(:steward_acs, :obsidian_vault_path, tmp)

    on_exit(fn ->
      Application.put_env(:steward_acs, :obsidian_vault_path, original_vault)
      File.rm_rf(tmp)
    end)

    %{tmp: tmp}
  end

  test "prompt editor binds phx-change/submit so edits can save with a success flash" do
    source = File.read!("lib/acs_web/live/acs_live/prompts_live.ex")

    refute source =~ ~s(phx-input=),
           "phx-input is not a LiveView binding; edits never reached the server"

    assert source =~ ~s(phx-change="editor-input")
    assert source =~ ~s(phx-submit="save")
    assert source =~ "Prompt saved successfully"
    assert source =~ "Failed to save prompt"
  end

  test "writing a vault override is what Prompts.load returns", %{tmp: tmp} do
    org = Acs.Org.current()
    dir = Path.join([tmp, "orgs", org, "prompts", "memory"])
    File.mkdir_p!(dir)
    path = Path.join(dir, "intake.md")

    assert :ok = File.write(path, "custom intake body\n")
    assert Prompts.load("memory", "intake") == "custom intake body"
  end
end
