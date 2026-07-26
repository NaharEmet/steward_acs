defmodule Acs.Observability.EventsTest do
  use ExUnit.Case, async: true

  alias Acs.Observability.AxiomLogBackend
  alias Acs.Observability.Events

  test "put_context binds Logger metadata used by Axiom allowlist" do
    Events.put_context(org: "prod", agent_id: "Ada", role: "admin", request_id: "req-1")

    meta = Logger.metadata()
    assert meta[:org] == "prod"
    assert meta[:agent_id] == "Ada"
    assert meta[:role] == "admin"
    assert meta[:request_id] == "req-1"
  after
    Logger.reset_metadata([])
  end

  test "exports new structured fields through AxiomLogBackend" do
    event =
      AxiomLogBackend.to_event(:info, "tool done", nil,
        module: Acs.MCP.Tools,
        action: "claim_work",
        agent_id: "Ada",
        org: "default",
        role: "admin",
        status: "ok",
        latency_ms: 12,
        component: "Acs.MCP.Tools",
        live_view: "AcsWeb.AcsLive.Tools",
        page: "/tools",
        service: "steward_acs",
        count: 3,
        request_id: "req-9"
      )

    assert event["action"] == "claim_work"
    assert event["agent_id"] == "Ada"
    assert event["org"] == "default"
    assert event["role"] == "admin"
    assert event["status"] == "ok"
    assert event["latency_ms"] == 12
    assert event["component"] == "Acs.MCP.Tools"
    assert event["live_view"] == "AcsWeb.AcsLive.Tools"
    assert event["page"] == "/tools"
    assert event["service"] == "steward_acs"
    assert event["count"] == 3
    assert event["request_id"] == "req-9"
  end
end
