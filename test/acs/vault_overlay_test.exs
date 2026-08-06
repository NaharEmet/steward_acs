defmodule Acs.VaultOverlayTest do
  use Acs.DataCase, async: false

  alias Acs.Memory.Loader, as: MemoryLoader
  alias Acs.Skills.Store
  alias Acs.Specs.Loader, as: SpecsLoader

  setup do
    vault = Path.join(System.tmp_dir!(), "vault_overlay_#{System.unique_integer([:positive])}")
    original_vault = Application.get_env(:steward_acs, :obsidian_vault_path)
    original_multi = Application.get_env(:steward_acs, :multi_tenant)
    original_org = Application.get_env(:steward_acs, :org_name)
    original_specs_env = System.get_env("SPECS_PATH")
    original_specs_config = Application.get_env(:steward_acs, SpecsLoader)

    Application.put_env(:steward_acs, :obsidian_vault_path, vault)
    Application.put_env(:steward_acs, :multi_tenant, false)
    Application.put_env(:steward_acs, :org_name, "prod")
    Application.delete_env(:steward_acs, SpecsLoader)
    System.delete_env("SPECS_PATH")
    Acs.Org.put_current("prod")

    on_exit(fn ->
      restore_env(:obsidian_vault_path, original_vault)
      restore_env(:multi_tenant, original_multi)
      restore_env(:org_name, original_org)

      if original_specs_config,
        do: Application.put_env(:steward_acs, SpecsLoader, original_specs_config),
        else: Application.delete_env(:steward_acs, SpecsLoader)

      if original_specs_env,
        do: System.put_env("SPECS_PATH", original_specs_env),
        else: System.delete_env("SPECS_PATH")

      Acs.Org.clear_request_org()
      File.rm_rf!(vault)
    end)

    %{vault: vault}
  end

  test "partial canonical migration keeps unrelated legacy memories and canonical wins duplicates" do
    canonical = Acs.Org.memory_dir("prod")
    legacy = Acs.Org.legacy_memory_dir("prod")
    File.mkdir_p!(Path.join(canonical, "notes"))
    File.mkdir_p!(Path.join(legacy, "notes"))

    File.write!(Path.join(legacy, "notes/legacy.yaml"), "id: legacy")
    File.write!(Path.join(legacy, "notes/shared.yaml"), "source: legacy")
    File.write!(Path.join(canonical, "notes/shared.yaml"), "source: canonical")

    files = MemoryLoader.list_files_for_org("prod")
    assert Path.join(legacy, "notes/legacy.yaml") in files
    assert Path.join(canonical, "notes/shared.yaml") in files
    refute Path.join(legacy, "notes/shared.yaml") in files
  end

  test "skills merge canonical and actual non-default configured-org legacy layout", %{
    vault: vault
  } do
    legacy = Path.join([vault, "skills", "orgs", "prod"])
    canonical = Acs.Org.skills_dir("prod")
    File.mkdir_p!(legacy)
    File.mkdir_p!(canonical)

    write_skill(Path.join(legacy, "legacy.md"), "Legacy")
    write_skill(Path.join(legacy, "shared.md"), "Legacy shared")
    write_skill(Path.join(canonical, "shared.md"), "Canonical shared")

    assert Store.get_skill("legacy").name == "Legacy"
    assert Store.get_skill("shared").name == "Canonical shared"
  end

  test "default-org legacy roots do not recursively expose nested tenant trees", %{vault: vault} do
    Application.put_env(:steward_acs, :org_name, "default")
    Acs.Org.put_current("default")
    nested = Path.join([vault, "skills", "orgs", "victim"])
    File.mkdir_p!(nested)
    write_skill(Path.join(nested, "secret.md"), "Victim secret")

    assert Store.get_skill("orgs/victim/secret") == nil
    assert {:error, :invalid_app} = SpecsLoader.load("orgs", "victim/app/spec")
  end

  test "non-configured tenants retain their exact legacy read locations", %{vault: vault} do
    Acs.Org.put_current("acme")
    legacy_skills = Path.join([vault, "skills", "orgs", "acme"])
    File.mkdir_p!(legacy_skills)
    write_skill(Path.join(legacy_skills, "tenant.md"), "Tenant legacy")

    assert Store.get_skill("tenant").name == "Tenant legacy"
  end

  test "specs and prompts use per-file canonical then legacy precedence", %{vault: vault} do
    canonical_specs = Acs.Org.specs_dir("prod")
    legacy_specs = Path.join([vault, "specs", "orgs", "prod"])
    File.mkdir_p!(Path.join(canonical_specs, "demo"))
    File.mkdir_p!(Path.join(legacy_specs, "demo"))
    File.write!(Path.join(legacy_specs, "demo/legacy.yaml"), "id: legacy")
    File.write!(Path.join(legacy_specs, "demo/shared.yaml"), "id: old")
    File.write!(Path.join(canonical_specs, "demo/shared.yaml"), "id: new")

    assert {:ok, specs} = SpecsLoader.list(app: "demo")
    assert Enum.any?(specs, &(&1.path == "legacy" and &1.file_path =~ legacy_specs))
    assert Enum.any?(specs, &(&1.path == "shared" and &1.file_path =~ canonical_specs))
    refute Enum.any?(specs, &(&1.path == "shared" and &1.file_path =~ legacy_specs))

    legacy_prompts = Path.join([vault, "prompts", "skills"])
    canonical_prompts = Path.join(Acs.Org.prompts_dir("prod"), "skills")
    File.mkdir_p!(legacy_prompts)
    File.mkdir_p!(canonical_prompts)
    File.write!(Path.join(legacy_prompts, "legacy.md"), "legacy prompt")
    File.write!(Path.join(legacy_prompts, "shared.md"), "old prompt")
    File.write!(Path.join(canonical_prompts, "shared.md"), "new prompt")

    assert Acs.Prompts.load("skills", "legacy") == "legacy prompt"
    assert Acs.Prompts.load("skills", "shared") == "new prompt"
  end

  test "vault readers and tool discovery reject symlink escapes", %{vault: _vault} do
    outside = Path.join(System.tmp_dir!(), "vault_outside_#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)

    write_skill(Path.join(outside, "leak.md"), "Leaked")

    skills = Acs.Org.skills_dir("prod")
    File.mkdir_p!(skills)
    File.ln_s!(Path.join(outside, "leak.md"), Path.join(skills, "leak.md"))
    assert Store.get_skill("leak") == nil

    memories = Acs.Org.memory_dir("prod")
    File.mkdir_p!(memories)
    File.write!(Path.join(outside, "memory.yaml"), "id: leaked")
    memory_link = Path.join(memories, "escape.yaml")
    File.ln_s!(Path.join(outside, "memory.yaml"), memory_link)
    assert {:error, reason} = MemoryLoader.load_file(memory_link)
    assert reason =~ "Unsafe symlinked vault path"

    prompts = Path.join(Acs.Org.prompts_dir("prod"), "skills")
    File.mkdir_p!(prompts)
    File.write!(Path.join(outside, "prompt.md"), "secret")
    File.ln_s!(Path.join(outside, "prompt.md"), Path.join(prompts, "escape.md"))
    assert Acs.Prompts.load("skills", "escape", default: "safe") == "safe"

    tools = Acs.Org.tools_dir("prod")
    File.mkdir_p!(Path.dirname(tools))
    File.ln_s!(outside, tools)

    refute Enum.any?(Acs.MCP.ToolLoader.sources(), fn
             {:tenant, "prod", _path} -> true
             _ -> false
           end)
  end

  test "watchers accept only their own canonical artifact subtrees", %{vault: vault} do
    memory = Path.join(Acs.Org.memory_dir("prod"), "notes/a.md")
    skill = Path.join(Acs.Org.skills_dir("prod"), "a.md")
    spec = Path.join(Acs.Org.specs_dir("prod"), "app/a.yaml")
    prompt = Path.join(Acs.Org.prompts_dir("prod"), "app/a.md")
    tool = Path.join(Acs.Org.tools_dir("prod"), "a.yaml")

    assert Acs.Memory.FileWatcher.memory_file_event?(memory)

    assert Acs.Memory.FileWatcher.memory_file_event?(
             Path.join(Acs.Org.legacy_memory_dir("prod"), "notes/legacy.md")
           )

    refute Acs.Memory.FileWatcher.memory_file_event?(skill)
    refute Acs.Memory.FileWatcher.memory_file_event?(spec)
    refute Acs.Memory.FileWatcher.memory_file_event?(prompt)
    refute Acs.Memory.FileWatcher.memory_file_event?(tool)

    assert Acs.Specs.FileWatcher.spec_file_event?(spec)
    refute Acs.Specs.FileWatcher.spec_file_event?(memory)
    refute Acs.Specs.FileWatcher.spec_file_event?(skill)
    refute Acs.Specs.FileWatcher.spec_file_event?(prompt)

    assert Acs.MCP.Tools.FileWatcher.tenant_tool_file?(tool, vault)
    refute Acs.MCP.Tools.FileWatcher.tenant_tool_file?(spec, vault)

    refute Acs.MCP.Tools.FileWatcher.tenant_tool_file?(
             Path.join(Acs.Org.tools_dir("prod"), "nested/a.yaml"),
             vault
           )
  end

  defp write_skill(path, name) do
    File.write!(path, "---\nname: #{name}\nstatus: proposed\n---\n\n#{name}\n")
  end

  defp restore_env(key, nil), do: Application.delete_env(:steward_acs, key)
  defp restore_env(key, value), do: Application.put_env(:steward_acs, key, value)
end
