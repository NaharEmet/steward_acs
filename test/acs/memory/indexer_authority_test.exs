defmodule Acs.Memory.IndexerAuthorityTest do
  use Acs.DataCase, async: false

  alias Acs.AuthorityLevels
  alias Acs.Memory.{Indexer, Schema}
  alias Acs.Repo

  setup do
    org = "idx-auth-#{System.unique_integer([:positive])}"
    AuthorityLevels.ensure_defaults!(org)
    Acs.Org.put_request_org(org)
    on_exit(fn -> Acs.Org.clear_request_org() end)
    %{org: org}
  end

  test "list_memories without agent_role does not bypass rank", %{org: org} do
    insert!(org, "high-secret", 1)
    insert!(org, "standard-ok", 3)

    listed =
      Indexer.list_memories(
        org: org,
        status: "approved",
        authority_sort_order: 3,
        agent_role: "collaborator",
        agent_id: "viewer@acme.com"
      )

    titles = Enum.map(listed, & &1.title)
    assert "standard-ok" in titles
    refute "high-secret" in titles

    # Missing role must not open the rank gate (falls back to lowest clearance).
    listed_nil_role =
      Indexer.list_memories(org: org, status: "approved", agent_id: "viewer@acme.com")

    titles_nil = Enum.map(listed_nil_role, & &1.title)
    assert "standard-ok" in titles_nil
    refute "high-secret" in titles_nil
  end

  test "indexer enforces full high/elevated/standard read matrix", %{org: org} do
    insert!(org, "mem-high", 1)
    insert!(org, "mem-elevated", 2)
    insert!(org, "mem-standard", 3)
    insert!(org, "mem-unranked", nil)

    expected = %{
      1 => ["mem-high", "mem-elevated", "mem-standard", "mem-unranked"],
      2 => ["mem-elevated", "mem-standard", "mem-unranked"],
      3 => ["mem-standard", "mem-unranked"]
    }

    for {viewer_order, visible} <- expected do
      titles =
        Indexer.list_memories(
          org: org,
          status: "approved",
          authority_sort_order: viewer_order,
          agent_role: "collaborator",
          agent_id: "viewer-#{viewer_order}@acme.com"
        )
        |> Enum.map(& &1.title)
        |> Enum.filter(&String.starts_with?(&1, "mem-"))
        |> Enum.sort()

      assert titles == Enum.sort(visible),
             "viewer order #{viewer_order} saw #{inspect(titles)}, expected #{inspect(visible)}"
    end
  end

  test "ranked memories do not leak across orgs", %{org: org} do
    other = "idx-auth-other-#{System.unique_integer([:positive])}"
    AuthorityLevels.ensure_defaults!(other)

    insert!(org, "org-a-high", 1)
    insert!(other, "org-b-high", 1)

    titles =
      Indexer.list_memories(
        org: org,
        status: "approved",
        authority_sort_order: 1,
        agent_role: "collaborator",
        agent_id: "exec@acme.com"
      )
      |> Enum.map(& &1.title)

    assert "org-a-high" in titles
    refute "org-b-high" in titles
  end

  test "personal high-ranked memory remains visible to its owner", %{org: org} do
    insert!(org, "mine-personal", 1, visibility: "personal", created_by_agent: "owner@acme.com")

    listed =
      Indexer.list_memories(
        org: org,
        status: "approved",
        authority_sort_order: 3,
        agent_role: "collaborator",
        agent_id: "owner@acme.com"
      )

    assert Enum.any?(listed, &(&1.title == "mine-personal"))
  end

  test "background jobs scan every org and see ranked memories", %{org: org} do
    insert!(org, "job-visible", 1)

    titles =
      [status: "approved", org: :all, system: true, limit: 500]
      |> Indexer.list_memories()
      |> Enum.map(& &1.title)

    assert "job-visible" in titles
  end

  test "cross-org scan without system: true does not crash and hides high rank", %{org: org} do
    insert!(org, "hidden-high", 1)
    insert!(org, "visible-unranked", nil)

    # No principal + org: :all used to raise FunctionClauseError in viewer_sort_order.
    listed =
      Indexer.list_memories(status: "approved", org: :all, limit: 500)

    titles = Enum.map(listed, & &1.title)
    assert "visible-unranked" in titles
    refute "hidden-high" in titles
  end

  test "system: false still enforces clearance for an agent viewer", %{org: org} do
    insert!(org, "exec-only", 1)

    listed =
      Indexer.list_memories(
        org: org,
        status: "approved",
        authority_level_slug: "standard",
        agent_id: "member@acme.com"
      )

    refute Enum.any?(listed, &(&1.title == "exec-only"))
  end

  defp insert!(org, title, order, opts \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %Schema{}
    |> Schema.changeset(%{
      id: "mem-#{System.unique_integer([:positive])}",
      org: org,
      title: title,
      content: title,
      kind: "observation",
      scope_path: "audit/#{title}",
      status: "approved",
      visibility: Keyword.get(opts, :visibility, "org"),
      created_by_agent: Keyword.get(opts, :created_by_agent),
      authority_sort_order: order,
      importance: 5,
      inserted_at: now,
      updated_at: now
    })
    |> Repo.insert!()
  end
end
