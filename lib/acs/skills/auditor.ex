defmodule Acs.Skills.Auditor do
  @moduledoc """
  GenServer that periodically audits skill files using LLM evaluation.

  Audit prompts live in `priv/prompts/skills/evaluate.md` (or the Obsidian
  vault `prompts/skills/evaluate.md`) and are editable without recompilation.
  """

  use GenServer
  require Logger

  alias Acs.LLM
  alias Acs.Skills.Store

  @interval 60_000
  @max_retries 3
  @backoff_delays [2_000, 5_000, 15_000]

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
  def handle_info(:audit, %{running: true} = state), do: {:noreply, state}

  @impl true
  def handle_info(:audit, state) do
    state = %{state | running: true}
    audit_all()
    schedule_audit()
    {:noreply, %{state | running: false}}
  end

  @impl true
  def handle_cast(:trigger, %{running: true} = state) do
    Logger.debug("[Acs.Skills.Auditor] Audit already running, skipping trigger")
    {:noreply, state}
  end

  @impl true
  def handle_cast(:trigger, state) do
    send(self(), :audit)
    {:noreply, state}
  end

  defp schedule_audit do
    Process.send_after(self(), :audit, audit_interval())
  end

  def audit_all(skills \\ nil) do
    skills =
      (skills || Store.list_skills())
      |> Enum.map(fn meta -> Store.get_skill(meta["name"]) end)
      |> Enum.reject(&is_nil/1)

    Logger.info("[Acs.Skills.Auditor] Auditing #{length(skills)} skills")

    max_conc =
      Application.get_env(:steward_acs, :skill_auditor_max_concurrency, 5)

    results =
      skills
      |> Task.async_stream(&audit_one/1, max_concurrency: max_conc, timeout: :infinity)
      |> Enum.map(fn
        {:ok, result} -> result
        {:error, reason} -> %{audit_status: "error", audit_reasoning: inspect(reason)}
      end)
      |> Enum.reject(&is_nil/1)

    ok = Enum.count(results, fn r -> r.audit_status == "ok" end)
    needs = Enum.count(results, fn r -> r.audit_status == "needs_improvement" end)
    failing = Enum.count(results, fn r -> r.audit_status == "failing" end)

    Logger.info(
      "[Acs.Skills.Auditor] Audit complete: #{ok} ok, #{needs} needs_improvement, #{failing} failing"
    )

    results
  end

  defp audit_one(skill) do
    case audit_with_retry(skill, @max_retries, @backoff_delays) do
      {:ok, result} ->
        result

      {:error, reason} ->
        %{name: skill.name, audit_status: "error", audit_reasoning: inspect(reason)}
    end
  end

  defp audit_with_retry(_skill, 0, _delays) do
    {:error, :max_retries}
  end

  defp audit_with_retry(skill, retries_left, [delay | rest]) do
    case LLM.evaluate_skill(skill.name, skill_attrs(skill)) do
      {:ok, evaluation} ->
        {:ok, apply_evaluation(skill, evaluation)}

      {:error, :no_providers_enabled} ->
        {:error, :no_providers_enabled}

      {:error, reason} ->
        Logger.warning(
          "[Acs.Skills.Auditor] Audit failed for #{skill.name}: #{inspect(reason)}. Retrying..."
        )

        Process.sleep(delay)
        audit_with_retry(skill, retries_left - 1, rest)
    end
  end

  defp audit_with_retry(skill, retries_left, []) do
    audit_with_retry(skill, retries_left, @backoff_delays)
  end

  defp skill_attrs(skill) do
    %{
      name: skill.name,
      description: skill.description || "",
      content: skill.content || "",
      tags: skill.tags || []
    }
  end

  defp apply_evaluation(skill, evaluation) do
    recommendation =
      evaluation["recommendation"] || evaluation[:recommendation] || "needs_improvement"

    quality_score =
      evaluation["quality_score"] || evaluation[:quality_score] || 3

    audit_status = recommendation_to_status(recommendation)
    audit_score = min(10, max(0, quality_score * 2))

    reasoning =
      evaluation["reasoning"] || evaluation[:reasoning] || "LLM audit completed"

    result = %{
      name: skill.name,
      audit_status: audit_status,
      audit_score: audit_score,
      audited_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      audit_reasoning: reasoning
    }

    Store.write_audit_fields(skill.name, result)
    result
  end

  defp recommendation_to_status("ok"), do: "ok"
  defp recommendation_to_status("failing"), do: "failing"
  defp recommendation_to_status(_), do: "needs_improvement"
end
