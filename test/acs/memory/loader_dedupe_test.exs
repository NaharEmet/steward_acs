defmodule Acs.Memory.LoaderDedupeTest do
  use Acs.DataCase, async: false

  alias Acs.Memory.Loader

  setup do
    vault = Path.join(System.tmp_dir!(), "loader_dedupe_#{System.unique_integer([:positive])}")
    original_vault = Application.get_env(:steward_acs, :obsidian_vault_path)

    Application.put_env(:steward_acs, :obsidian_vault_path, vault)

    on_exit(fn ->
      if original_vault,
        do: Application.put_env(:steward_acs, :obsidian_vault_path, original_vault),
        else: Application.delete_env(:steward_acs, :obsidian_vault_path)

      File.rm_rf!(vault)
    end)

    :ok
  end

  test "a memory re-saved under a new scope does not get reverted by its orphaned copy" do
    root = Acs.Org.memory_dir()

    # Same id, two scopes — what happens when a memory's scope_path changes.
    write_memory(root, "old/scope", "proposed", "2026-07-28T05:17:14.000000Z")
    write_memory(root, "new/scope", "rejected", "2026-08-01T07:22:45.000000Z")

    {:ok, memories, _quarantined} = Loader.load_all()

    assert [%Acs.Memory{id: "observation_dedupe_probe", status: "rejected"}] =
             Enum.filter(memories, &(&1.id == "observation_dedupe_probe"))
  end

  defp write_memory(root, scope, status, updated_at) do
    dir = Path.join(root, scope)
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "observation_dedupe_probe.yaml"), """
    id: observation_dedupe_probe
    kind: observation
    title: Dedupe probe
    content: A memory that exists at two paths because its scope_path changed.
    scope_path: #{scope}
    status: #{status}
    importance: 3
    org: #{Acs.Org.current()}
    created_at: "2026-07-28T05:17:14.000000Z"
    updated_at: "#{updated_at}"
    """)
  end
end
