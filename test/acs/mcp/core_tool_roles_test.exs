defmodule Acs.MCP.CoreToolRolesTest do
  use ExUnit.Case, async: true

  alias Acs.MCP.CoreToolRoles

  test "collaborators may use consolidated and fine-grained tools for their audiences" do
    for tool <- ~w(steward_ask steward_write steward_work) do
      assert CoreToolRoles.authorized?(tool, "collaborator", :chat)
      refute CoreToolRoles.authorized?(tool, "collaborator", :coding)
    end

    for tool <- ~w(ask get_started save_memory create_work skill_get lock_file) do
      assert CoreToolRoles.authorized?(tool, "collaborator", :coding)
      refute CoreToolRoles.authorized?(tool, "collaborator", :chat)
    end
  end

  test "collaborators cannot use admin-only tools" do
    for tool <- ~w(query read_file read_dir write_file get_logs skill_audit_status) do
      refute CoreToolRoles.authorized?(tool, "collaborator")
    end
  end

  test "chat surface is exactly the three consolidated tools" do
    assert MapSet.new(CoreToolRoles.chat_surface()) ==
             MapSet.new(~w(steward_ask steward_write steward_work))
  end

  test "tool definitions produce exact chat surface and preserve coding names" do
    definitions = Acs.MCP.Tools.list_tools()

    chat_names =
      definitions
      |> Enum.filter(&CoreToolRoles.authorized?(&1["name"], "collaborator", :chat))
      |> Enum.map(& &1["name"])
      |> MapSet.new()

    coding_names =
      definitions
      |> Enum.filter(&CoreToolRoles.authorized?(&1["name"], "collaborator", :coding))
      |> Enum.map(& &1["name"])
      |> MapSet.new()

    assert chat_names == MapSet.new(~w(steward_ask steward_write steward_work))
    assert MapSet.subset?(MapSet.new(~w(ask get_started save_memory lock_file)), coding_names)
    refute "steward_ask" in coding_names
  end

  test "all chat tools are always loaded without search hints" do
    assert CoreToolRoles.eager_priority() == ~w(steward_ask steward_write steward_work)

    for tool <- CoreToolRoles.chat_surface() do
      definition = CoreToolRoles.with_eager_meta(%{"name" => tool, "description" => "x"})
      assert definition["_meta"]["anthropic/alwaysLoad"] == true
      refute Map.has_key?(definition["_meta"], "anthropic/searchHint")
    end
  end

  test "chat tools sort before coding tools" do
    tools = [
      %{"name" => "save_memory"},
      %{"name" => "steward_work"},
      %{"name" => "steward_ask"},
      %{"name" => "steward_write"}
    ]

    sorted = Enum.sort_by(tools, &CoreToolRoles.list_sort_key/1)

    assert Enum.map(sorted, & &1["name"]) ==
             ["steward_ask", "steward_write", "steward_work", "save_memory"]
  end
end
