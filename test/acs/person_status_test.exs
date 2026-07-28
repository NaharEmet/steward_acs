defmodule Acs.PersonStatusTest do
  use Acs.DataCase, async: true

  alias Acs.MCP.Tools.PersonHandlers
  alias Acs.PersonStatus

  setup do
    org = Acs.Org.current()
    %{org: org}
  end

  test "upsert and get by email", %{org: org} do
    assert {:ok, person} =
             PersonStatus.upsert(%{
               "org" => org,
               "email" => "CEO@Acme.com",
               "name" => "Jane Doe",
               "status" => "CEO",
               "rank" => "high",
               "updated_by" => "tester"
             })

    assert person.email == "ceo@acme.com"
    assert person.rank == "high"
    assert PersonStatus.high_rank?(person)

    found = PersonStatus.get(org, email: "ceo@acme.com")
    assert found.id == person.id
    assert found.status == "CEO"
  end

  test "get_person_status MCP returns found false then set saves", %{org: org} do
    assert {:ok, %{found: false}} =
             PersonHandlers.get_person_status(%{"name" => "New Person", "_auth_org" => org})

    assert {:ok, %{person: saved}} =
             PersonHandlers.set_person_status(%{
               "name" => "New Person",
               "email" => "new@acme.com",
               "status" => "Engineer",
               "rank" => "standard",
               "_auth_agent_id" => "alice@acme.com"
             })

    assert saved.rank == "standard"

    assert {:ok, %{found: true, status: "Engineer"}} =
             PersonHandlers.get_person_status(%{"email" => "new@acme.com"})
  end
end
