defmodule Acs.MCP.CoreToolRolesTest do
  use ExUnit.Case, async: true

  alias Acs.MCP.CoreToolRoles

  test "collaborators may use coordination tools" do
    assert CoreToolRoles.authorized?("claim_work", "collaborator")
    assert CoreToolRoles.authorized?("save_memory", "collaborator")
  end

  test "collaborators cannot use admin-only tools" do
    refute CoreToolRoles.authorized?("query", "collaborator")
    refute CoreToolRoles.authorized?("write_file", "collaborator")
    refute CoreToolRoles.authorized?("get_logs", "collaborator")
  end

  test "service role may read time but not arbitrary SQL" do
    assert CoreToolRoles.authorized?("time", "service")
    refute CoreToolRoles.authorized?("query", "service")
  end
end
