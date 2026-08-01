defmodule Acs.AbacTest do
  use ExUnit.Case, async: true

  alias Acs.Abac
  alias Acs.Specs.Entry

  describe "visible?/2 for org KB memories and coding-agent documents" do
    test "admin sees all visibility levels" do
      ctx = %Abac{agent_role: "admin", agent_id: "admin@acme.com"}

      assert Abac.visible?(ctx, %{"visibility" => "org"})
      assert Abac.visible?(ctx, %{"visibility" => "team", "team" => "platform"})
      assert Abac.visible?(ctx, %Entry{visibility: "project", project: "acs"})
    end

    test "collaborator without allowlists sees every shared scope" do
      ctx = %Abac{agent_role: "collaborator"}

      assert Abac.visible?(ctx, %{"visibility" => "org"})
      assert Abac.visible?(ctx, %{"visibility" => "team", "team" => "platform"})
      assert Abac.visible?(ctx, %{"visibility" => "project", "project" => "acs"})
    end

    test "team and project allowlists do not restrict reads" do
      ctx = %Abac{agent_role: "collaborator", allowed_teams: ["platform"]}

      assert Abac.visible?(ctx, %{"visibility" => "team", "team" => "platform"})
      assert Abac.visible?(ctx, %{"visibility" => "team", "team" => "sales"})

      ctx = %Abac{agent_role: "collaborator", allowed_projects: ["acs"]}

      assert Abac.visible?(ctx, %{"visibility" => "project", "project" => "acs"})
      assert Abac.visible?(ctx, %{"visibility" => "project", "project" => "other"})
    end
  end

  describe "validate_write/2" do
    test "collaborator can write org-visible content" do
      ctx = %Abac{agent_role: "collaborator"}

      assert :ok = Abac.validate_write(ctx, %{"visibility" => "org"})
    end

    # Regression: OAuth users always arrive with an empty team allowlist, so gating
    # writes on it made team visibility unreachable for every connector user.
    test "collaborator can write any team, including one outside its allowlist" do
      ctx = %Abac{agent_role: "collaborator", allowed_teams: ["platform"]}

      assert :ok = Abac.validate_write(ctx, %{"visibility" => "team", "team" => "platform"})
      assert :ok = Abac.validate_write(ctx, %{"visibility" => "team", "team" => "sales"})

      ctx = %Abac{agent_role: "collaborator"}

      assert :ok = Abac.validate_write(ctx, %{"visibility" => "team", "team" => "sales_cs"})
      assert :ok = Abac.validate_write(ctx, %{"visibility" => "project", "project" => "acs"})
    end

    test "team visibility requires team field" do
      ctx = %Abac{agent_role: "admin"}

      assert {:error, msg} = Abac.validate_write(ctx, %{"visibility" => "team"})
      assert msg =~ "team"
    end
  end

  describe "memory_status_for_write/2" do
    test "collaborator org-wide writes are proposed for review" do
      ctx = %Abac{agent_role: "collaborator"}

      assert "proposed" =
               Abac.memory_status_for_write(ctx, %{"visibility" => "org", "kind" => "context"})
    end

    # Team visibility must not become a way around review now that anyone can write it.
    test "collaborator team-scoped writes are also proposed for review" do
      ctx = %Abac{agent_role: "collaborator", allowed_teams: ["platform"]}

      assert "proposed" =
               Abac.memory_status_for_write(ctx, %{"visibility" => "team", "team" => "platform"})
    end

    test "admin writes keep default status" do
      ctx = %Abac{agent_role: "admin"}

      assert is_nil(
               Abac.memory_status_for_write(ctx, %{"visibility" => "team", "team" => "platform"})
             )
    end
  end
end
