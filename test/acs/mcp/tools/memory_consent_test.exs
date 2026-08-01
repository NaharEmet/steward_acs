defmodule Acs.MCP.Tools.MemoryConsentTest do
  use Acs.DataCase, async: false

  alias Acs.MCP.Tools.MemoryHandlers
  alias Acs.PersonStatus

  setup do
    org = Acs.Org.current()

    {:ok, _} =
      PersonStatus.upsert(%{
        "org" => org,
        "email" => "ceo@acme.com",
        "name" => "CEO",
        "status" => "CEO",
        "rank" => "high",
        "updated_by" => "test"
      })

    :ok
  end

  test "about entity without visibility returns scope question" do
    assert {:ok, %{status: "needs_scope_choice", saved: false, question: question}} =
             MemoryHandlers.save_memory(%{
               "kind" => "learning",
               "title" => "CEO preference unique #{System.unique_integer([:positive])}",
               "content" => "Prefers weekly board packs",
               "scope_path" => "acme/exec",
               "about_type" => "person",
               "about_email" => "ceo@acme.com",
               "_auth_agent_id" => "alice@acme.com",
               "_auth_role" => "collaborator"
             })

    assert question =~ "scoped"
  end

  test "about company with visibility saves" do
    title = "Acme net-30 unique #{System.unique_integer([:positive])}"

    assert {:ok, %{id: id}} =
             MemoryHandlers.save_memory(%{
               "kind" => "learning",
               "title" => title,
               "content" => "Acme Corp standard payment terms are net-30",
               "scope_path" => "acme/sales",
               "about_type" => "company",
               "about_name" => "Acme Corp",
               "visibility" => "org",
               "intake_confirmed" => true,
               "_auth_agent_id" => "alice@acme.com",
               "_auth_role" => "collaborator"
             })

    memory = Acs.Memory.Indexer.get_memory(id, Acs.Org.current())
    assert memory.visibility == "org"
    tags = decode_tags(memory)
    assert Enum.any?(tags, &String.contains?(&1, "about-type:company"))
  end

  test "sensitive-looking content saves with suggested_sensitive note" do
    title = "Q2 revenue unique #{System.unique_integer([:positive])}"

    assert {:ok, result} =
             MemoryHandlers.save_memory(%{
               "kind" => "learning",
               "title" => title,
               "content" => "Q2 revenue is $4.2M driven by enterprise renewals",
               "scope_path" => "acme/finance",
               "visibility" => "org",
               "intake_confirmed" => true,
               "_auth_agent_id" => "alice@acme.com",
               "_auth_role" => "collaborator"
             })

    assert result.suggested_sensitive == true
    assert result.note =~ "sensitive"
    assert result.id
  end

  test "confidential saves as personal without extra confirmation flags" do
    title = "Private note unique #{System.unique_integer([:positive])}"

    assert {:ok, %{id: id}} =
             MemoryHandlers.save_memory(%{
               "kind" => "learning",
               "title" => title,
               "content" => "Private preference that stays with the saver",
               "scope_path" => "acme/exec",
               "about_type" => "person",
               "about_email" => "ceo@acme.com",
               "confidential" => true,
               "intake_confirmed" => true,
               "_auth_agent_id" => "alice@acme.com",
               "_auth_role" => "collaborator"
             })

    memory = Acs.Memory.Indexer.get_memory(id, Acs.Org.current())
    assert memory.visibility == "personal"
  end

  test "stamps authority from the writer, not the about-person" do
    org = Acs.Org.current()
    Acs.AuthorityLevels.ensure_defaults!(org)
    title = "Writer stamp unique #{System.unique_integer([:positive])}"

    assert {:ok, %{id: id}} =
             MemoryHandlers.save_memory(%{
               "kind" => "learning",
               "title" => title,
               "content" => "Fact about the CEO written by a standard-clearance member",
               "scope_path" => "acme/exec",
               "about_type" => "person",
               "about_email" => "ceo@acme.com",
               "visibility" => "org",
               "intake_confirmed" => true,
               "_auth_agent_id" => "alice@acme.com",
               "_auth_role" => "collaborator",
               "_auth_authority_level" => "standard",
               "_auth_authority_sort_order" => 3
             })

    memory = Acs.Memory.Indexer.get_memory(id, org)
    # CEO person rank is high (1); writer clearance is standard (3).
    assert memory.authority_sort_order == 3
  end

  defp decode_tags(%{tags_json: json}) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp decode_tags(_), do: []
end
