defmodule Acs.MCP.CoreToolRolesTest do
  use ExUnit.Case, async: true

  alias Acs.MCP.CoreToolRoles

  test "collaborators may use coordination and skill tools" do
    assert CoreToolRoles.authorized?("claim_work", "collaborator")
    assert CoreToolRoles.authorized?("save_memory", "collaborator")
    assert CoreToolRoles.authorized?("set_memory_status", "collaborator")
    assert CoreToolRoles.authorized?("create_work", "collaborator")
    assert CoreToolRoles.authorized?("skill_get", "collaborator")
    assert CoreToolRoles.authorized?("skill_save", "collaborator")
    assert CoreToolRoles.authorized?("get_started", "collaborator")
  end

  test "collaborators cannot use admin-only tools" do
    refute CoreToolRoles.authorized?("query", "collaborator")
    refute CoreToolRoles.authorized?("read_file", "collaborator")
    refute CoreToolRoles.authorized?("read_dir", "collaborator")
    refute CoreToolRoles.authorized?("write_file", "collaborator")
    refute CoreToolRoles.authorized?("get_logs", "collaborator")
    refute CoreToolRoles.authorized?("skill_audit_status", "collaborator")
  end

  test "chat audience is limited to chat_surface" do
    assert CoreToolRoles.authorized?("ask", "collaborator", :chat)
    assert CoreToolRoles.authorized?("documents_propose", "collaborator", :chat)
    assert CoreToolRoles.authorized?("skill_save", "collaborator", :chat)
    assert CoreToolRoles.authorized?("create_work", "collaborator", :chat)
    assert CoreToolRoles.authorized?("get_person_status", "collaborator", :chat)
    assert CoreToolRoles.authorized?("set_person_status", "collaborator", :chat)
    assert CoreToolRoles.authorized?("set_memory_status", "collaborator", :chat)
    refute CoreToolRoles.authorized?("specs_propose", "collaborator", :chat)
    refute CoreToolRoles.authorized?("lock_file", "collaborator", :chat)
    refute CoreToolRoles.authorized?("query_memories", "collaborator", :chat)
    refute CoreToolRoles.authorized?("generate_guidance_packet", "collaborator", :chat)
  end

  test "coding audience keeps lock_file for collaborators" do
    assert CoreToolRoles.authorized?("lock_file", "collaborator", :coding)
    assert CoreToolRoles.authorized?("query_memories", "collaborator", :coding)
  end

  test "service role may read time but not arbitrary SQL" do
    assert CoreToolRoles.authorized?("time", "service")
    refute CoreToolRoles.authorized?("query", "service")
  end

  test "chat_surface includes documents_propose not specs_propose" do
    surface = MapSet.new(CoreToolRoles.chat_surface())
    assert "skill_get" in surface
    assert "skill_save" in surface
    assert "create_work" in surface
    assert "ask" in surface
    assert "set_memory_status" in surface
    assert "documents_propose" in surface
    assert "get_person_status" in surface
    assert "set_person_status" in surface
    refute "specs_propose" in surface
  end
end
