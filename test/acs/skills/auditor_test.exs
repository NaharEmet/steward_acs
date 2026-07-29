defmodule Acs.Skills.AuditorTest do
  use ExUnit.Case, async: true

  alias Acs.Skills.Auditor

  test "skips skills that already have audit frontmatter" do
    skills = [
      %{
        "name" => "already-ok",
        "id" => "already-ok",
        "audit_status" => "ok",
        "audited_at" => "2026-07-01T00:00:00Z"
      }
    ]

    {results, audited} = Auditor.audit_all(skills)

    assert results == []
    assert audited == MapSet.new()
  end

  test "treats missing audit fields as not yet audited (no BadBooleanError)" do
    skills = [
      %{"name" => "bare", "id" => "bare"}
    ]

    # Name is cached so we never call Store/LLM — only exercises already_audited?/1
    # on metas without audit keys.
    {results, audited} = Auditor.audit_all(skills, MapSet.new(["bare"]))

    assert results == []
    assert MapSet.member?(audited, "bare")
  end

  test "in-process audited cache prevents a second pass for the same name" do
    skills = [
      %{"name" => "needs-audit", "id" => "needs-audit"}
    ]

    cached = MapSet.new(["needs-audit"])
    {results, audited} = Auditor.audit_all(skills, cached)

    assert results == []
    assert MapSet.member?(audited, "needs-audit")
  end

  test "dedupes duplicate relative ids that share a skill name before get_skill" do
    skills = [
      %{"name" => "dup", "id" => "dup"},
      %{"name" => "dup", "id" => "orgs/default/dup"}
    ]

    cached = MapSet.new(["dup"])
    {results, _audited} = Auditor.audit_all(skills, cached)

    assert results == []
  end
end
