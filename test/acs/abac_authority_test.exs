defmodule Acs.AbacAuthorityTest do
  use ExUnit.Case, async: true

  alias Acs.Abac

  test "collaborator with elevated clearance cannot read high-ranked memory" do
    ctx = %Abac{
      agent_role: "collaborator",
      agent_id: "bob@acme.com",
      authority_sort_order: 2
    }

    refute Abac.visible?(ctx, %{
             "visibility" => "org",
             "authority_sort_order" => 1
           })

    assert Abac.visible?(ctx, %{
             "visibility" => "org",
             "authority_sort_order" => 2
           })

    assert Abac.visible?(ctx, %{
             "visibility" => "org",
             "authority_sort_order" => 3
           })

    assert Abac.visible?(ctx, %{"visibility" => "org"})
  end

  test "admin clearance still applies — role does not bypass rank" do
    ctx = %Abac{
      agent_role: "admin",
      agent_id: "admin@acme.com",
      authority_sort_order: 3
    }

    refute Abac.visible?(ctx, %{"visibility" => "org", "authority_sort_order" => 1})
    assert Abac.visible?(ctx, %{"visibility" => "org", "authority_sort_order" => 3})

    refute Abac.visible?(ctx, %{
             "visibility" => "personal",
             "created_by_agent" => "other@acme.com"
           })
  end

  test "personal memories skip rank for their owner" do
    ctx = %Abac{
      agent_role: "collaborator",
      agent_id: "owner@acme.com",
      authority_sort_order: 3
    }

    assert Abac.visible?(ctx, %{
             "visibility" => "personal",
             "created_by_agent" => "owner@acme.com",
             "authority_sort_order" => 1
           })

    refute Abac.visible?(ctx, %{
             "visibility" => "personal",
             "created_by_agent" => "other@acme.com",
             "authority_sort_order" => 3
           })
  end
end
