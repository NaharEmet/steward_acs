defmodule Acs.AbacPersonalTest do
  use ExUnit.Case, async: true

  alias Acs.Abac

  describe "personal visibility" do
    test "creator can see their personal memory; others cannot (including admin)" do
      item = %{
        "visibility" => "personal",
        "created_by" => %{"id" => "alice@acme.com", "type" => "user"}
      }

      assert Abac.visible?(%Abac{agent_role: "collaborator", agent_id: "alice@acme.com"}, item)
      refute Abac.visible?(%Abac{agent_role: "collaborator", agent_id: "bob@acme.com"}, item)
      refute Abac.visible?(%Abac{agent_role: "admin", agent_id: "admin@acme.com"}, item)
      assert Abac.visible?(%Abac{agent_role: "admin", agent_id: "alice@acme.com"}, item)
    end

    test "personal write is always allowed" do
      ctx = %Abac{agent_role: "collaborator", agent_id: "alice@acme.com"}
      assert :ok = Abac.validate_write(ctx, %{"visibility" => "personal"})
    end

    test "personal writes skip proposed status" do
      ctx = %Abac{agent_role: "collaborator", agent_id: "alice@acme.com"}

      assert is_nil(Abac.memory_status_for_write(ctx, %{"visibility" => "personal"}))
    end

    test "rejects invalid visibility" do
      ctx = %Abac{agent_role: "admin"}
      assert {:error, msg} = Abac.validate_write(ctx, %{"visibility" => "secret"})
      assert msg =~ "personal"
    end
  end
end
