defmodule Acs.Observability.AgentOps do
  @moduledoc """
  Agent-facing usage telemetry for Steward.

  Emits flat, APL-friendly `agent.tool` / `agent.feedback` events so coding
  agents (and Axiom dashboards) can analyze Claude/chat vs coding usage without
  parsing free-text logs.

  Learning signals (filter on `signal`):
  - `works` — successful retrieve with hits, or useful guidance feedback
  - `gap_empty` — retrieve returned nothing (knowledge missing or bad scope)
  - `gap_info` — feedback says info was needed
  - `misuse_discovery` — unknown tool name
  - `misuse_write` — write with no prior retrieve in the same chain
  - `surprise_persist` — write after an empty retrieve (unplanned fill / invent)
  - `win` — feedback with learned_for_agents (what worked, often unplanned)
  - `pain` — feedback with had_issues / improvements

  Dual-write:
  - Axiom `steward_meta_analytics` (or primary logs dataset) when Axiom is enabled
  - `acs_tool_operations` via MetaHarness when `META_HARNESS_ENABLED=true`
  """

  alias Acs.Observability.AxiomLogExporter

  @event_tool "agent.tool"
  @event_feedback "agent.feedback"

  @retrieve_tools ~w(ask query_memories query_specs skill_get specs_get generate_guidance_packet get_started)
  @write_tools ~w(save_memory documents_propose specs_propose skill_save set_memory_status specs_approve specs_reject)
  @task_tools ~w(create_work claim_work release_work submit_task_feedback list_tasks lock_file unlock_file get_present_status)

  @doc """
  Log one MCP tool invocation.

  ## Options
  - `:tool_name` (required)
  - `:result` — tool return value (used for status + result_count)
  - `:latency_ms`, `:agent_id`, `:org`, `:audience`, `:role`
  - `:execution_id`, `:task_id`
  - `:scope_path`, `:kind` — knowledge context when present on the call
  - `:discovery` — true when the tool name was unknown
  """
  def log_tool(opts) when is_list(opts) do
    tool_name = Keyword.fetch!(opts, :tool_name)
    result = Keyword.get(opts, :result)
    discovery? = Keyword.get(opts, :discovery, false)

    {status, error_type, error_message} =
      if discovery?, do: {"discovery", nil, nil}, else: result_status(result)

    result_count = result_count(tool_name, result)
    empty_result = is_integer(result_count) and result_count == 0 and status == "success"
    chain_id = chain_id(opts)
    sequence = next_sequence(chain_id)
    family = tool_family(tool_name)
    audience = normalize_audience(Keyword.get(opts, :audience))
    chain = note_chain(chain_id, family, empty_result)

    write_without_retrieve = family == "write" and not chain.seen_retrieve
    after_empty_retrieve = family == "write" and chain.last_empty == true

    signal =
      tool_signal(
        discovery?,
        family,
        empty_result,
        result_count,
        write_without_retrieve,
        after_empty_retrieve
      )

    event = %{
      "_time" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "message" => @event_tool,
      "event" => @event_tool,
      "severity" => "INFO",
      "level" => "info",
      "service" => "steward_acs",
      "module" => "Acs.Observability.AgentOps",
      "tool_name" => tool_name,
      "tool_family" => family,
      "status" => status,
      "signal" => signal,
      "latency_ms" => Keyword.get(opts, :latency_ms),
      "agent_id" => Keyword.get(opts, :agent_id),
      "org" => Keyword.get(opts, :org),
      "audience" => audience,
      "role" => Keyword.get(opts, :role),
      "execution_id" => Keyword.get(opts, :execution_id),
      "task_id" => Keyword.get(opts, :task_id),
      "scope_path" => truncate(Keyword.get(opts, :scope_path), 200),
      "kind" => Keyword.get(opts, :kind),
      "execution_chain_id" => chain_id,
      "sequence_order" => sequence,
      "result_count" => result_count,
      "empty_result" => empty_result,
      "write_without_retrieve" => write_without_retrieve,
      "after_empty_retrieve" => after_empty_retrieve,
      "tool_discovered" => discovery?,
      "error_type" => error_type,
      "error_message" => error_message && String.slice(to_string(error_message), 0, 500)
    }

    enqueue_axiom(event)

    maybe_meta_harness(
      tool_name,
      status,
      opts,
      error_type,
      error_message,
      chain_id,
      sequence,
      discovery?
    )

    :ok
  rescue
    _ -> :ok
  end

  @doc "Log structured task feedback for agent/dashboard analysis."
  def log_feedback(opts) when is_list(opts) do
    learned = Keyword.get(opts, :learned_for_agents)
    issues = Keyword.get(opts, :had_issues)
    improvements = Keyword.get(opts, :improvements)
    info_needed = Keyword.get(opts, :info_needed)
    guidance_useful = Keyword.get(opts, :guidance_useful)

    signal = feedback_signal(guidance_useful, learned, issues, improvements, info_needed)

    event = %{
      "_time" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "message" => @event_feedback,
      "event" => @event_feedback,
      "severity" => "INFO",
      "level" => "info",
      "service" => "steward_acs",
      "module" => "Acs.Observability.AgentOps",
      "tool_name" => "submit_task_feedback",
      "tool_family" => "task",
      "signal" => signal,
      "agent_id" => Keyword.get(opts, :agent_id),
      "org" => Keyword.get(opts, :org),
      "audience" => normalize_audience(Keyword.get(opts, :audience)),
      "task_id" => Keyword.get(opts, :task_id),
      "guidance_useful" => guidance_useful,
      "has_learned" => present?(learned),
      "has_issues" => present?(issues),
      "has_improvements" => present?(improvements),
      "has_info_needed" => present?(info_needed),
      "info_needed" => truncate(info_needed, 500),
      "learned_for_agents" => truncate(learned, 500),
      "had_issues" => truncate(issues, 500),
      "improvements" => truncate(improvements, 500)
    }

    enqueue_axiom(event)
    :ok
  rescue
    _ -> :ok
  end

  @doc false
  def tool_family(name) when name in @retrieve_tools, do: "retrieve"
  def tool_family(name) when name in @write_tools, do: "write"
  def tool_family(name) when name in @task_tools, do: "task"
  def tool_family(_), do: "other"

  @doc false
  def tool_signal(true, _, _, _, _, _), do: "misuse_discovery"

  def tool_signal(_, "retrieve", true, _, _, _), do: "gap_empty"

  def tool_signal(_, "retrieve", _, count, _, _) when is_integer(count) and count > 0,
    do: "works"

  def tool_signal(_, "write", _, _, true, _), do: "misuse_write"

  def tool_signal(_, "write", _, _, false, true), do: "surprise_persist"

  def tool_signal(_, "write", _, _, _, _), do: "works"

  def tool_signal(_, _, _, _, _, _), do: nil

  @doc false
  def feedback_signal(true, learned, issues, improvements, info_needed) do
    cond do
      present?(learned) -> "win"
      present?(info_needed) -> "gap_info"
      present?(issues) or present?(improvements) -> "pain"
      true -> "works"
    end
  end

  def feedback_signal(_, learned, issues, improvements, info_needed) do
    cond do
      present?(learned) -> "win"
      present?(info_needed) -> "gap_info"
      present?(issues) or present?(improvements) -> "pain"
      true -> nil
    end
  end

  # ── Axiom ───────────────────────────────────────────────────────────────────

  defp enqueue_axiom(event) do
    event = Map.reject(event, fn {_k, v} -> is_nil(v) or v == "" end)

    # Prefer dedicated agent-ops dataset; always mirror to primary logs so data
    # is never lost when steward_meta_analytics is missing or ingest is failing.
    if Process.whereis(Acs.Observability.AgentOpsExporter) do
      AxiomLogExporter.enqueue(event, Acs.Observability.AgentOpsExporter)
    end

    if Process.whereis(AxiomLogExporter) do
      AxiomLogExporter.enqueue(event)
    end

    :ok
  end

  # ── Meta harness (optional local table) ─────────────────────────────────────

  defp maybe_meta_harness(
         tool_name,
         status,
         opts,
         error_type,
         error_message,
         chain_id,
         sequence,
         discovery?
       ) do
    if System.get_env("META_HARNESS_ENABLED", "false") == "true" and
         Code.ensure_loaded?(Acs.MetaHarness.OperationLogger) do
      Acs.MetaHarness.OperationLogger.log_async(
        tool_name,
        status_atom(status),
        Keyword.get(opts, :latency_ms),
        error_type,
        error_message && to_string(error_message),
        Keyword.get(opts, :agent_id),
        Keyword.get(opts, :execution_id),
        execution_chain_id: chain_id,
        sequence_order: sequence,
        tool_discovered: discovery?,
        params_hash: params_hash(opts, status)
      )
    end
  end

  defp status_atom("success"), do: :success
  defp status_atom("failure"), do: :failure
  defp status_atom("discovery"), do: :discovery
  defp status_atom(_), do: :unknown

  defp params_hash(opts, status) do
    # Compact, non-PII fingerprint agents can group on.
    base =
      "#{Keyword.get(opts, :audience)}|#{status}|#{Keyword.get(opts, :scope_path)}|#{Keyword.get(opts, :kind)}"

    :crypto.hash(:sha256, base) |> Base.encode16(case: :lower) |> binary_part(0, 12)
  end

  # ── Result extraction ───────────────────────────────────────────────────────

  defp result_status({:ok, _}), do: {"success", nil, nil}
  defp result_status(:ok), do: {"success", nil, nil}
  defp result_status({:sleep, _, _}), do: {"success", nil, nil}

  defp result_status({:error, reason}) when is_binary(reason),
    do: {"failure", String.slice(reason, 0, 50), reason}

  defp result_status({:error, %{reason: reason}}),
    do: {"failure", String.slice(to_string(reason), 0, 50), reason}

  defp result_status({:error, reason}),
    do: {"failure", inspect(reason) |> String.slice(0, 50), inspect(reason)}

  defp result_status(other),
    do: {"unknown", "unexpected_result", inspect(other)}

  defp result_count("ask", {:ok, %{summary: summary}}) when is_map(summary) do
    (Map.get(summary, :memory_count) || Map.get(summary, "memory_count") || 0) +
      (Map.get(summary, :document_count) || Map.get(summary, "document_count") || 0)
  end

  defp result_count("query_memories", {:ok, payload}) when is_map(payload) do
    list_len(payload, [:memories, "memories", :results, "results"]) ||
      int_field(payload, [:count, "count"])
  end

  defp result_count("query_specs", {:ok, payload}) when is_map(payload) do
    list_len(payload, [:specs, "specs", :documents, "documents", :results, "results"]) ||
      int_field(payload, [:count, "count"])
  end

  defp result_count("skill_get", {:ok, payload}) when is_map(payload) do
    cond do
      is_list(payload[:skills]) -> length(payload[:skills])
      is_list(payload["skills"]) -> length(payload["skills"])
      is_list(payload[:catalog]) -> length(payload[:catalog])
      is_list(payload["catalog"]) -> length(payload["catalog"])
      is_binary(payload[:name]) or is_binary(payload["name"]) -> 1
      is_list(payload[:results]) -> length(payload[:results])
      true -> nil
    end
  end

  defp result_count("generate_guidance_packet", {:ok, payload}) when is_map(payload) do
    memories = list_len(payload, [:relevant_memories, "relevant_memories", :memories, "memories"]) || 0
    skills = list_len(payload, [:relevant_skills, "relevant_skills"]) || 0
    specs = list_len(payload, [:relevant_specs, "relevant_specs"]) || 0
    memories + skills + specs
  end

  defp result_count("list_tasks", {:ok, payload}) when is_map(payload) do
    list_len(payload, [:tasks, "tasks"]) || int_field(payload, [:count, "count"])
  end

  defp result_count(_, _), do: nil

  defp list_len(payload, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(payload, key) do
        list when is_list(list) -> length(list)
        _ -> nil
      end
    end)
  end

  defp int_field(payload, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(payload, key) do
        n when is_integer(n) -> n
        _ -> nil
      end
    end)
  end

  defp chain_id(opts) do
    Keyword.get(opts, :execution_id) ||
      Keyword.get(opts, :task_id) ||
      case {Keyword.get(opts, :agent_id), Keyword.get(opts, :org)} do
        {agent, org} when is_binary(agent) and is_binary(org) -> "#{org}:#{agent}"
        {agent, _} when is_binary(agent) -> agent
        _ -> "anon"
      end
  end

  defp next_sequence(chain_id) do
    ensure_seq_table()
    :ets.update_counter(__MODULE__.Seq, chain_id, {2, 1}, {chain_id, 0})
  end

  defp note_chain(chain_id, family, empty_result) do
    ensure_chain_table()

    prev =
      case :ets.lookup(__MODULE__.Chain, chain_id) do
        [{^chain_id, state}] -> state
        [] -> %{seen_retrieve: false, last_empty: false}
      end

    state =
      case family do
        "retrieve" -> %{prev | seen_retrieve: true, last_empty: empty_result == true}
        _ -> prev
      end

    :ets.insert(__MODULE__.Chain, {chain_id, state})
    state
  end

  defp ensure_seq_table do
    case :ets.whereis(__MODULE__.Seq) do
      :undefined ->
        try do
          :ets.new(__MODULE__.Seq, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  defp ensure_chain_table do
    case :ets.whereis(__MODULE__.Chain) do
      :undefined ->
        try do
          :ets.new(__MODULE__.Chain, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  defp normalize_audience(nil), do: nil
  defp normalize_audience(a) when a in [:chat, "chat", :knowledge, "knowledge"], do: "chat"
  defp normalize_audience(a) when a in [:coding, "coding", :mcp, "mcp"], do: "coding"
  defp normalize_audience(a), do: to_string(a)

  defp present?(v) when is_binary(v), do: String.trim(v) != ""
  defp present?(_), do: false

  defp truncate(nil, _), do: nil
  defp truncate(v, n) when is_binary(v), do: String.slice(v, 0, n)
  defp truncate(v, n), do: v |> inspect() |> String.slice(0, n)
end
