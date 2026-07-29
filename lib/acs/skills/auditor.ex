defmodule Acs.Skills.Auditor do
  @moduledoc """
  GenServer that periodically audits skill files using LLM evaluation.

  Audit prompts live in `priv/prompts/skills/evaluate.md` (or the Obsidian
  vault `prompts/skills/evaluate.md`) and are editable without recompilation.

  Skips skills that already have audit frontmatter. Also keeps an in-process
  name cache so a failed disk write cannot re-burn LLM tokens every cycle
  (ponytail: process-lifetime skip; post-save `audit_soon/1` still re-runs).
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

  @doc "Queue a single-skill audit after skill_save (best-effort; no-op if auditor down)."
  def audit_soon(name) when is_binary(name) do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:audit_one, name})
    end

    :ok
  end

  def audit_soon(_), do: :ok

  def audit_interval do
    Application.get_env(:steward_acs, :skill_auditor_interval, @interval)
  end

  @impl true
  def init(_opts) do
    Logger.info("[Acs.Skills.Auditor] Starting with interval: #{audit_interval()}ms")
    schedule_audit()
    {:ok, %{running: false, audited: MapSet.new()}}
  end

  @impl true
  def handle_info(:audit, %{running: true} = state), do: {:noreply, state}

  @impl true
  def handle_info(:audit, state) do
    state = %{state | running: true}
    {_results, audited} = audit_all(nil, state.audited)
    schedule_audit()
    {:noreply, %{state | running: false, audited: audited}}
  end

  @impl true
  def handle_info({:audit_one, name}, state) do
    audited =
      case Store.get_skill(name) do
        nil ->
          Logger.debug("[Acs.Skills.Auditor] skill '#{name}' not found for post-save audit")
          state.audited

        skill ->
          # Allow re-audit after skill_save even if cached from a prior cycle.
          audited = MapSet.delete(state.audited, skill.name)

          case audit_one(skill) do
            %{name: n} when is_binary(n) -> MapSet.put(audited, n)
            _ -> audited
          end
      end

    {:noreply, %{state | audited: audited}}
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

  @impl true
  def handle_cast({:audit_one, name}, state) do
    send(self(), {:audit_one, name})
    {:noreply, state}
  end

  defp schedule_audit do
    Process.send_after(self(), :audit, audit_interval())
  end

  @doc """
  Audit skills that lack frontmatter audit fields and are not in `audited` cache.

  Returns `{results, updated_audited}`.
  """
  def audit_all(skills \\ nil, audited \\ MapSet.new()) do
    candidates =
      (skills || Store.list_skills())
      |> Enum.uniq_by(& &1["name"])
      |> Enum.reject(fn meta ->
        already_audited?(meta) or MapSet.member?(audited, meta["name"])
      end)
      |> Enum.map(fn meta -> Store.get_skill(meta["id"] || meta["name"]) end)
      |> Enum.reject(&is_nil/1)
      # get_skill(id) can still collide on name across duplicate trees — one LLM call each
      |> Enum.uniq_by(& &1.name)

    Logger.info("[Acs.Skills.Auditor] Auditing #{length(candidates)} skills")

    max_conc =
      Application.get_env(:steward_acs, :skill_auditor_max_concurrency, 5)

    results =
      candidates
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

    audited =
      Enum.reduce(results, audited, fn
        %{name: name}, acc when is_binary(name) -> MapSet.put(acc, name)
        _, acc -> acc
      end)

    {results, audited}
  end

  defp already_audited?(meta) do
    status = meta["audit_status"]
    audited_at = meta["audited_at"]

    is_binary(status) and status != "" and is_binary(audited_at) and audited_at != ""
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
      audience: skill.metadata["audience"] || "coding",
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

    # Prefer id so nested duplicate trees write the file we just evaluated.
    case Store.write_audit_fields(skill.id || skill.name, result) do
      :ok ->
        maybe_update_governance_status(skill, audit_status)

      other ->
        Logger.error(
          "[Acs.Skills.Auditor] Failed to persist audit for #{skill.name} (#{skill.id}): #{inspect(other)}"
        )
    end

    result
  end

  # Mirror memory/document LLM approval: ok → approved, failing → rejected.
  # needs_improvement stays proposed for human review.
  defp maybe_update_governance_status(skill, "ok") do
    case Store.update_status(skill.id || skill.name, "approved", "llm") do
      :ok ->
        Logger.info("[Acs.Skills.Auditor] skill '#{skill.name}' auto-approved by LLM")

      other ->
        Logger.error(
          "[Acs.Skills.Auditor] Failed to approve skill '#{skill.name}': #{inspect(other)}"
        )
    end
  end

  defp maybe_update_governance_status(skill, "failing") do
    case Store.update_status(skill.id || skill.name, "rejected", "llm") do
      :ok ->
        Logger.info("[Acs.Skills.Auditor] skill '#{skill.name}' auto-rejected by LLM")

      other ->
        Logger.error(
          "[Acs.Skills.Auditor] Failed to reject skill '#{skill.name}': #{inspect(other)}"
        )
    end
  end

  defp maybe_update_governance_status(_skill, _), do: :ok

  defp recommendation_to_status("ok"), do: "ok"
  defp recommendation_to_status("failing"), do: "failing"
  defp recommendation_to_status(_), do: "needs_improvement"
end
