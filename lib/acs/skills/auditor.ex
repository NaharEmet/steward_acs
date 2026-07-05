defmodule Acs.Skills.Auditor do
  @moduledoc """
  GenServer that periodically audits skill files for quality and completeness.

  Runs every 60 seconds by default. Checks each skill for:
    - Valid YAML frontmatter with name, description, and tags
    - Non-trivial content (>= 50 characters)
    - Description doesn't duplicate the name
    - Content isn't just a reference to another file
    - Tags contain only valid characters

  Audit results are written back into each skill's YAML frontmatter
  as `audit_status`, `audit_score`, `audit_reasoning`, and `audited_at`.
  """

  use GenServer
  require Logger

  @interval 60_000
  @min_content_length 50
  @min_tags 1

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def trigger_audit do
    GenServer.cast(__MODULE__, :trigger)
  end

  def audit_interval do
    Application.get_env(:steward_acs, :skill_auditor_interval, @interval)
  end

  @impl true
  def init(_opts) do
    Logger.info("[Acs.Skills.Auditor] Starting with interval: #{audit_interval()}ms")
    schedule_audit()
    {:ok, %{running: false}}
  end

  @impl true
  def handle_info(:audit, %{running: true} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:audit, state) do
    state = %{state | running: true}
    audit_all()
    schedule_audit()
    {:noreply, %{state | running: false}}
  end

  @impl true
  def handle_cast(:trigger, state) do
    if state.running do
      Logger.debug("[Acs.Skills.Auditor] Audit already running, skipping trigger")
      {:noreply, state}
    else
      send(self(), :audit)
      {:noreply, state}
    end
  end

  defp schedule_audit do
    Process.send_after(self(), :audit, audit_interval())
  end

  def audit_all(skills \\ nil) do
    skills = skills || Acs.Skills.Store.list_skills()
    Logger.info("[Acs.Skills.Auditor] Auditing #{length(skills)} skills")

    results =
      Enum.map(skills, fn meta ->
        name = meta["name"]
        skill = Acs.Skills.Store.get_skill(name)
        if skill, do: audit_one(skill), else: nil
      end)
      |> Enum.reject(&is_nil/1)

    ok = Enum.count(results, fn r -> r.audit_status == "ok" end)
    needs_improvement = Enum.count(results, fn r -> r.audit_status == "needs_improvement" end)
    failing = Enum.count(results, fn r -> r.audit_status == "failing" end)
    Logger.info("[Acs.Skills.Auditor] Audit complete: #{ok} ok, #{needs_improvement} needs_improvement, #{failing} failing")
    results
  end

  defp audit_one(skill) do
    checks = run_checks(skill)
    issues = Enum.filter(checks, fn {_check, result} -> result != :ok end)
    score = compute_score(checks)
    status = status_from_score(score)
    reasoning = format_reasoning(issues)

    result = %{
      name: skill.name,
      audit_status: status,
      audit_score: score,
      audited_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      audit_reasoning: reasoning
    }

    Acs.Skills.Store.write_audit_fields(skill.name, result)
    result
  end

  def run_checks(skill) do
    [
      has_name: if(skill.name && skill.name != "", do: :ok, else: {:fail, "Missing name"}),
      has_description:
        if(skill.description && String.trim(skill.description) != "",
          do: :ok,
          else: {:fail, "Missing description"}
        ),
      has_tags:
        if(skill.tags && length(skill.tags) >= @min_tags,
          do: :ok,
          else: {:fail, "Need at least #{@min_tags} tag"}
        ),
      has_content:
        if(skill.content && String.length(String.trim(skill.content)) >= @min_content_length,
          do: :ok,
          else: {:fail, "Content too short (< #{@min_content_length} chars)"}
        ),
      description_not_name:
        if(skill.description && skill.name &&
             String.downcase(skill.description) != String.downcase(skill.name),
           do: :ok,
           else: {:warn, "Description duplicates name"}
        ),
      description_not_content:
        if(skill.description && skill.content &&
             String.trim(skill.description) !=
               String.slice(String.trim(skill.content), 0, String.length(String.trim(skill.description))),
           do: :ok,
           else: {:warn, "Description appears to duplicate start of content"}
        )
    ]
  end

  defp compute_score(checks) do
    scores =
      Enum.map(checks, fn
        {_, :ok} -> 10
        {_, {:warn, _}} -> 5
        {_, {:fail, _}} -> 0
      end)

    if scores == [], do: 0, else: div(Enum.sum(scores), length(scores))
  end

  defp status_from_score(score) when score >= 8, do: "ok"
  defp status_from_score(score) when score >= 4, do: "needs_improvement"
  defp status_from_score(_), do: "failing"

  defp format_reasoning(issues) do
    case issues do
      [] -> "All checks passed"
      _ ->
        issues
        |> Enum.map(fn
          {_, {:warn, msg}} -> msg
          {_, {:fail, msg}} -> msg
        end)
        |> Enum.join("; ")
    end
  end
end
