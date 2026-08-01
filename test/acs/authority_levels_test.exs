defmodule Acs.AuthorityLevelsTest do
  use Acs.DataCase, async: false

  alias Acs.AuthorityLevels
  alias Acs.PersonStatus

  setup do
    org = "auth-lv-#{System.unique_integer([:positive])}"
    %{org: org}
  end

  test "seeds default high/elevated/standard with human labels", %{org: org} do
    levels = AuthorityLevels.list(org)
    assert length(levels) == 3
    assert Enum.map(levels, & &1.slug) == ["high", "elevated", "standard"]
    assert Enum.map(levels, & &1.label) == ["Executive", "Senior", "Standard"]
  end

  test "resolve accepts slug or label", %{org: org} do
    AuthorityLevels.list(org)
    assert %{slug: "high"} = AuthorityLevels.resolve(org, "high")
    assert %{slug: "high"} = AuthorityLevels.resolve(org, "Executive")
  end

  test "can_read? hierarchy: viewer sees own level and lower" do
    assert AuthorityLevels.can_read?(2, nil)
    assert AuthorityLevels.can_read?(2, 2)
    assert AuthorityLevels.can_read?(2, 3)
    refute AuthorityLevels.can_read?(2, 1)
    assert AuthorityLevels.can_read?(nil, nil)
    refute AuthorityLevels.can_read?(nil, 1)
  end

  test "upsert enforces max 20 levels", %{org: org} do
    AuthorityLevels.list(org)

    for i <- 4..20 do
      assert {:ok, _} =
               AuthorityLevels.upsert(org, %{
                 "label" => "Level #{i}",
                 "slug" => "level-#{i}",
                 "sort_order" => i
               })
    end

    assert {:error, msg} =
             AuthorityLevels.upsert(org, %{
               "label" => "Overflow",
               "slug" => "overflow",
               "sort_order" => 21
             })

    assert msg =~ "at most 20"
  end

  test "PersonStatus rejects unknown rank", %{org: org} do
    AuthorityLevels.list(org)

    assert {:error, cs} =
             PersonStatus.upsert(%{
               "org" => org,
               "name" => "Pat",
               "status" => "IC",
               "rank" => "not-a-real-level"
             })

    assert cs.errors[:rank]
  end

  test "PersonStatus accepts label as rank", %{org: org} do
    AuthorityLevels.list(org)

    assert {:ok, person} =
             PersonStatus.upsert(%{
               "org" => org,
               "email" => "ceo-#{System.unique_integer([:positive])}@example.test",
               "name" => "Ceo",
               "status" => "CEO",
               "rank" => "Executive"
             })

    assert person.rank == "high"
    assert PersonStatus.high_rank?(person)
  end

  test "delete requires remap when persons use the level", %{org: org} do
    AuthorityLevels.list(org)

    assert {:ok, _} =
             PersonStatus.upsert(%{
               "org" => org,
               "email" => "senior-#{System.unique_integer([:positive])}@example.test",
               "name" => "Senior",
               "status" => "Lead",
               "rank" => "elevated"
             })

    assert {:error, :remap_required, info} = AuthorityLevels.delete(org, "elevated")
    assert info.promote_to.slug == "high"
    assert info.demote_to.slug == "standard"

    assert {:ok, result} = AuthorityLevels.delete(org, "elevated", remap: :demote)
    assert result.remapped_to.slug == "standard"
    refute Enum.any?(AuthorityLevels.list(org), &(&1.slug == "elevated"))
  end
end
