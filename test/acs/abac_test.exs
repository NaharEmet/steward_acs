defmodule Acs.AbacTest do
  use ExUnit.Case, async: true

  alias Acs.Abac
  alias Acs.Cognition.Entry

  describe "visible?/2 for org KB memories and coding-agent documents" do
    test "admin sees all visibility levels" do
      ctx = %Abac{agent_role: "admin"}

      assert Abac.visible?(ctx, %{"visibility" => "org"})
      assert Abac.visible?(ctx, %{"visibility" => "team", "team" => "platform"})
      assert Abac.visible?(ctx, %Entry{visibility: "project", project: "acs"})
    end

    test "collaborator without allowlists only sees org content" do
      ctx = %Abac{agent_role: "collaborator"}

      assert Abac.visible?(ctx, %{"visibility" => "org"})
      refute Abac.visible?(ctx, %{"visibility" => "team", "team" => "platform"})
      refute Abac.visible?(ctx, %{"visibility" => "project", "project" => "acs"})
    end

    test "collaborator with team allowlist sees org and matching team content" do
      ctx = %Abac{agent_role: "collaborator", allowed_teams: ["platform"]}

      assert Abac.visible?(ctx, %{"visibility" => "org"})
      assert Abac.visible?(ctx, %{"visibility" => "team", "team" => "platform"})
      refute Abac.visible?(ctx, %{"visibility" => "team", "team" => "sales"})
    end

    test "collaborator with project allowlist sees org and matching project content" do
      ctx = %Abac{agent_role: "collaborator", allowed_projects: ["acs"]}

      assert Abac.visible?(ctx, %{"visibility" => "project", "project" => "acs"})
      refute Abac.visible?(ctx, %{"visibility" => "project", "project" => "other"})
    end
  end

  describe "validate_write/2" do
    test "collaborator can write org-visible content" do
      ctx = %Abac{agent_role: "collaborator"}

      assert :ok = Abac.validate_write(ctx, %{"visibility" => "org"})
    end

    test "collaborator cannot write team content outside allowlist" do
      ctx = %Abac{agent_role: "collaborator", allowed_teams: ["platform"]}

      assert :ok = Abac.validate_write(ctx, %{"visibility" => "team", "team" => "platform"})
      assert {:error, _} = Abac.validate_write(ctx, %{"visibility" => "team", "team" => "sales"})
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

      assert "proposed" = Abac.memory_status_for_write(ctx, %{"visibility" => "org", "kind" => "context"})
    end

    test "collaborator team-scoped writes keep default status" do
      ctx = %Abac{agent_role: "collaborator", allowed_teams: ["platform"]}

      assert is_nil(Abac.memory_status_for_write(ctx, %{"visibility" => "team", "team" => "platform"}))
    end
  end
end
