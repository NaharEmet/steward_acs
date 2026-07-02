defmodule Acs.MCP.Tools.DiagnosticHandlers do
  @moduledoc """
  Handles diagnostic MCP tools for system health and introspection.

  ## Purpose

  Implements handler functions for diagnostic and health-check tools:
  schema-free SQL queries, tool help/listing, configuration lookup,
  connection diagnostics, code search, and memory pipeline health checks.

  ## Key Functions

  - `acs_query/1` — Runs a raw SQL query against the ACS database
  - `acs_help/1` — Lists MCP tools with filtering by category/level
  - `config_lookup/1` — Returns opencode configuration data (agents,
    skills, plugins, MCP)
  - `connection_diagnostic/1` — Checks reachability of ACS, database,
    and LLM services
  - `find_similar_code/1` — Semantic search across codebase memories
  - `memory_health_check/1` — Full memory pipeline health assessment
    including flow, throughput, DLQ, and stuck messages
  """
  require Logger

  def acs_query(%{"sql" => sql, "purpose" => purpose}) do
    case validate_read_only_sql(sql) do
      :ok ->
        Logger.info("[acs_query] purpose: #{purpose || "unknown"}, sql: #{String.slice(sql, 0, 100)}")

        case run_sql_query(sql) do
          {:ok, results} -> {:ok, %{row_count: length(results), results: results}}
          {:error, reason} -> {:error, "Query failed: #{reason}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def acs_help(args) do
    category_filter = args["category"]
    level_filter = args["level"]

    all_tools = Acs.MCP.ToolRegistry.list_tools()
    categories = Acs.MCP.ToolRegistry.list_categories()

    filtered_tools =
      all_tools
      |> Enum.filter(fn t ->
        matches_category = is_nil(category_filter) || t["category"] == category_filter
        tool_level = t["level"] || 2
        matches_level = is_nil(level_filter) || tool_level <= level_filter
        matches_category and matches_level
      end)

    tools_by_category =
      filtered_tools
      |> Enum.group_by(&(Map.get(&1, "category") || "uncategorized"))
      |> Enum.map(fn {cat, tools} ->
        {cat,
         Enum.map(tools, fn t ->
           %{
             name: t["name"],
             level: t["level"] || 2,
             description: t["description"],
             params: (t["params"] || []) |> Enum.map(fn p -> p["name"] end),
             required_params:
               (t["params"] || [])
               |> Enum.filter(fn p -> p["required"] end)
               |> Enum.map(fn p -> p["name"] end)
           }
         end)
         |> Enum.sort_by(& &1.name)}
      end)
      |> Enum.sort_by(fn {cat, _} -> cat end)
      |> Enum.into(%{})

    total_count = length(filtered_tools)

    {:ok,
     %{
       total_tools: total_count,
       categories: %{
         available: categories,
         filtered: Map.keys(tools_by_category)
       },
       tools: tools_by_category
     }}
  end

  def config_lookup(args) do
    path = args["path"] || "all"
    _key = args["key"]

    config_data = %{
      "agents" => %{
        description: "Agent configuration from opencode.json",
        path: ".opencode/agents.json"
      },
      "skills" => %{
        description: "Available skills from .opencode/skills/",
        path: ".opencode/skills/"
      },
      "plugins" => %{
        description: "Plugin configuration from .opencode/plugins.yaml",
        path: ".opencode/plugins.yaml"
      },
      "mcp" => %{
        description: "MCP server configuration",
        path: "config/"
      }
    }

    result =
      if path == "all" do
        config_data
      else
        case Map.get(config_data, path) do
          nil ->
            %{
              error:
                "Unknown config path: #{path}. Valid paths: agents, skills, plugins, mcp, all"
            }

          data ->
            %{path => data}
        end
      end

    {:ok, result}
  end

  def connection_diagnostic(args) do
    service = args["service"] || "all"
    _verbose = args["verbose"] || false

    checks = %{
      "acs" => fn -> check_acs_service() end,
      "database" => fn -> check_database_service() end,
      "llm" => fn -> check_llm_service() end
    }

    results =
      if service == "all" do
        Enum.map(checks, fn {name, check_fn} ->
          {name, check_fn.()}
        end)
        |> Enum.into(%{})
      else
        case Map.get(checks, service) do
          nil ->
            %{error: "Unknown service: #{service}. Valid: acs, database, llm, all"}

          check_fn ->
            %{service => check_fn.()}
        end
      end

    {:ok, %{diagnostics: results, timestamp: DateTime.utc_now() |> DateTime.to_iso8601()}}
  end

  def find_similar_code(args) do
    query = args["query"]
    limit = args["limit"] || 5
    scope = args["scope"]

    if is_nil(query) || query == "" do
      {:error, "Query is required"}
    else
      search_opts = [limit: limit]
      search_opts = if scope, do: Keyword.put(search_opts, :scope_path, scope), else: search_opts

      results = Acs.Memory.Search.search(query, search_opts)

      formatted_results =
        Enum.map(results, fn mem ->
          %{
            id: mem.id,
            title: mem.title,
            kind: mem.kind,
            scope_path: mem.scope_path,
            relevance: "semantic_match"
          }
        end)

      {:ok, %{results: formatted_results, count: length(formatted_results), query: query}}
    end
  end

  def memory_health_check(args) do
    org_id = args["org_id"]
    ext = extension_module()

    stats_response = ext.fetch_memory_stats(org_id)

    if is_map(stats_response) do
      do_memory_health_check(stats_response, org_id, ext)
    else
      Logger.warning(
        "[memory_health_check] Expected map from fetch_memory_stats, got: #{inspect(stats_response)}"
      )

      {:ok,
       %{
         health: %{status: "error", score: 0, message: "Invalid response from extension API"},
         flow: %{incoming: 0, processing: 0, stalled: 0, completed: 0},
         throughput: %{
           per_minute: nil,
           per_hour: nil,
           success_rate: nil,
           avg_cycle_time_ms: nil,
           cycles_last_hour: 0
         },
         transformation: %{messages: 0, records: 0, claims: 0, observations: 0},
         issues: [
           %{
             severity: "critical",
             code: "INVALID_API_RESPONSE",
             message:
               "fetch_memory_stats returned non-map: #{inspect(stats_response)}"
           }
         ],
         dlq: %{summary: %{}, recent_entries: []},
         stuck: %{count: 0, sample: []},
         pending: %{},
         pipeline_states: [],
         log_db: %{total: 0, errors_24h: 0, warnings_24h: 0, clusters: []},
         timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
       }}
    end
  end

  defp do_memory_health_check(stats_response, org_id, ext) do
    worker_status = Map.get(stats_response, "pipeline_worker_status") || %{}
    message_status_counts = Map.get(stats_response, "message_status_counts") || %{}
    dlq_summary = Map.get(stats_response, "dlq_summary") || %{}
    stuck_data = Map.get(stats_response, "stuck_classified_messages")
    pending_summary = Map.get(stats_response, "pending_items_summary") || %{}
    memory_totals = Map.get(stats_response, "memory_totals_by_org") || %{}
    recent_cycles = Map.get(stats_response, "recent_cycles") || []

    stuck_count = (stuck_data || %{}) |> Map.get(:count, 0)

    health = compute_memory_health(worker_status, dlq_summary, message_status_counts, stuck_count)
    flow_data = compute_memory_flow(message_status_counts, worker_status, dlq_summary)
    flow_metrics = compute_memory_flow_metrics(recent_cycles)

    transformation_flow =
      compute_transformation_flow(message_status_counts, memory_totals, org_id)

    issues =
      collect_memory_issues(
        worker_status,
        dlq_summary,
        message_status_counts,
        stuck_count,
        pending_summary
      )

    dlq_entries =
      ext.fetch_dlq_entries()
      |> Enum.take(10)
      |> Enum.map(fn entry ->
        %{
          id: entry["id"],
          message_id: entry["message_id"],
          original_message: entry["original_message"],
          error: entry["error"],
          failed_at: entry["failed_at"],
          retry_count: entry["retry_count"]
        }
      end)

    stuck_sample = (stuck_data || %{}) |> Map.get(:sample, [])

    pipeline_states = Map.get(stats_response, "pipeline_states") || []

    # Log DB stats
    log_db_stats = collect_log_db_stats()

    {:ok,
     %{
       health: health,
       flow: flow_data,
       throughput: flow_metrics,
       transformation: transformation_flow,
       issues: issues,
       dlq: %{
         summary: dlq_summary,
         recent_entries: dlq_entries
       },
       stuck: %{
         count: stuck_count,
         sample: stuck_sample
       },
       pending: pending_summary,
       pipeline_states: Enum.take(pipeline_states, 10),
       log_db: log_db_stats,
       timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
     }}
  end

  defp run_sql_query(sql) do
    case Ecto.Adapters.SQL.query(Acs.Repo, sql, [], log: false) do
      {:ok, result} ->
        {:ok,
         Enum.map(result.rows, fn row ->
           Enum.zip(result.columns, row) |> Enum.into(%{})
         end)}

      {:error, e} ->
        {:error, inspect(e)}
    end
  end

  @blocked_sql_keywords ~w(
    insert update delete drop alter create replace truncate attach detach
    pragma vacuum reindex grant revoke merge call execute
  )

  defp validate_read_only_sql(sql) when is_binary(sql) do
    trimmed = String.trim(sql)

    cond do
      trimmed == "" ->
        {:error, "Empty SQL query"}

      String.contains?(trimmed, ";") ->
        {:error, "Multiple SQL statements are not allowed"}

      not allowed_sql_prefix?(trimmed) ->
        {:error, "Only SELECT, WITH, and EXPLAIN queries are allowed"}

      contains_blocked_sql_keyword?(trimmed) ->
        {:error, "Write or DDL operations are not allowed"}

      true ->
        :ok
    end
  end

  defp validate_read_only_sql(_), do: {:error, "SQL must be a string"}

  defp allowed_sql_prefix?(sql) do
    normalized = String.downcase(sql)

    Enum.any?(~w(select with explain), fn prefix ->
      String.starts_with?(normalized, prefix)
    end)
  end

  defp contains_blocked_sql_keyword?(sql) do
    Enum.any?(@blocked_sql_keywords, fn keyword ->
      Regex.match?(~r/\b#{keyword}\b/i, sql)
    end)
  end

  defp check_acs_service do
    case Acs.Repo.query("SELECT 1") do
      {:ok, _} -> %{status: "ok", message: "ACS database reachable"}
      {:error, reason} -> %{status: "error", message: inspect(reason)}
    end
  end

  defp check_database_service do
    case Acs.Repo.query("SELECT 1") do
      {:ok, _} -> %{status: "ok", message: "Database connection active"}
      {:error, reason} -> %{status: "error", message: inspect(reason)}
    end
  end

  defp check_llm_service do
    case extension_module().fetch_llm_config() do
      %{minimax_key: minimax_key, nim_key: nim_key} when not is_nil(minimax_key) and not is_nil(nim_key) ->
        %{status: "ok", message: "Both LLM providers configured"}

      %{minimax_key: minimax_key} when not is_nil(minimax_key) ->
        %{status: "warn", message: "Only MiniMax configured, NIM missing"}

      %{nim_key: nim_key} when not is_nil(nim_key) ->
        %{status: "warn", message: "Only NIM configured, MiniMax missing"}

      _ ->
        %{status: "error", message: "No LLM providers configured"}
    end
  end

  defp compute_memory_health(worker_status, dlq_summary, message_status_counts, stuck_count) do
    issues = []

    issues =
      if (worker_status || %{}) |> Map.get(:stale?, false) do
        [{:critical, "Worker stale"} | issues]
      else
        issues
      end

    issues =
      if (dlq_summary || %{}) |> Map.get(:recent_hour, 0) > 10 do
        [{:critical, "DLQ surge"} | issues]
      else
        issues
      end

    issues =
      if stuck_count > 0 do
        [{:critical, "#{stuck_count} stuck messages"} | issues]
      else
        issues
      end

    issues =
      if (message_status_counts || %{}) |> Map.get("failed", 0) > 10 do
        [{:warning, "High failure rate"} | issues]
      else
        issues
      end

    issues =
      if (dlq_summary || %{}) |> Map.get(:total, 0) > 0 and
           (dlq_summary || %{}) |> Map.get(:recent_hour, 0) <= 10 do
        [{:warning, "DLQ has entries"} | issues]
      else
        issues
      end

    {level, score, summary} =
      case issues do
        [] ->
          {:healthy, 100, "All systems operational"}

        [{:critical, _} | _] when length(issues) >= 2 ->
          {:critical, 20, "#{length(issues)} critical issues"}

        [{:critical, first} | _] ->
          {:critical, 40, first}

        [{:warning, _} | _] when length(issues) >= 3 ->
          {:warning, 60, "#{length(issues)} warnings"}

        [{:warning, first} | _] ->
          {:warning, 80, first}

        _ ->
          {:healthy, 100, "All systems operational"}
      end

    %{level: level, score: score, summary: summary, issues: issues}
  end

  defp compute_memory_flow(message_status_counts, worker_status, dlq_summary) do
    pending = Map.get(message_status_counts, "pending", 0) || 0
    classified = Map.get(message_status_counts, "classified", 0) || 0
    inbound = pending + classified

    queue_stats =
      Map.get(worker_status, :queue_stats) || Map.get(worker_status, "queue_stats") || %{}

    queued = Map.get(queue_stats, :total) || Map.get(queue_stats, "total") || 0

    %{
      inbound: inbound,
      queued: queued,
      processing: pending,
      succeeded: Map.get(message_status_counts, "extracted", 0) || 0,
      failed: Map.get(message_status_counts, "failed", 0) || 0,
      dlq: Map.get(dlq_summary, :total, 0) || 0,
      unclassified: Map.get(message_status_counts, "unclassified", 0) || 0,
      skipped: Map.get(message_status_counts, "skipped", 0) || 0
    }
  end

  defp compute_memory_flow_metrics(recent_cycles) do
    if recent_cycles == [] do
      %{
        per_minute: nil,
        per_hour: nil,
        success_rate: nil,
        avg_cycle_time_ms: nil,
        cycles_last_hour: 0
      }
    else
      now = DateTime.utc_now()
      hour_ago = DateTime.add(now, -3600, :second)
      minute_ago = DateTime.add(now, -60, :second)

      last_hour_cycles =
        Enum.filter(recent_cycles, fn c ->
          c.started_at && DateTime.compare(c.started_at, hour_ago) == :gt
        end)

      last_minute_cycles =
        Enum.filter(recent_cycles, fn c ->
          c.started_at && DateTime.compare(c.started_at, minute_ago) == :gt
        end)

      per_minute =
        if length(last_minute_cycles) > 0 do
          total = Enum.reduce(last_minute_cycles, 0, fn c, acc -> acc + (c.processed || 0) end)
          Float.round(total / max(1, length(last_minute_cycles)), 2)
        else
          0.0
        end

      per_hour =
        if length(last_hour_cycles) > 0 do
          total = Enum.reduce(last_hour_cycles, 0, fn c, acc -> acc + (c.processed || 0) end)
          Float.round(total / max(1, length(last_hour_cycles)), 2)
        else
          0.0
        end

      total_processed = Enum.reduce(recent_cycles, 0, fn c, acc -> acc + (c.processed || 0) end)
      total_failed = Enum.reduce(recent_cycles, 0, fn c, acc -> acc + (c.failed || 0) end)
      total = total_processed + total_failed

      success_rate =
        if total > 0 do
          Float.round(total_processed / total * 100, 2)
        else
          nil
        end

      cycle_times =
        recent_cycles
        |> Enum.filter(fn c -> c.started_at && c.finished_at end)
        |> Enum.map(fn c -> DateTime.diff(c.finished_at, c.started_at, :millisecond) end)

      avg_cycle_time_ms =
        if cycle_times != [] do
          trunc(Enum.sum(cycle_times) / length(cycle_times))
        else
          nil
        end

      %{
        per_minute: per_minute,
        per_hour: per_hour,
        success_rate: success_rate,
        avg_cycle_time_ms: avg_cycle_time_ms,
        cycles_last_hour: length(last_hour_cycles)
      }
    end
  end

  defp compute_transformation_flow(message_status_counts, memory_totals, _org_id) do
    message_buckets = ~w(pending classified extracted unclassified failed skipped)

    total_messages =
      Enum.reduce(message_buckets, 0, fn bucket, acc ->
        acc + (Map.get(message_status_counts, bucket, 0) || 0)
      end)

    %{
      messages: total_messages,
      records: Map.get(memory_totals, :records, 0) || 0,
      claims: Map.get(memory_totals, :claims, 0) || 0,
      observations: Map.get(memory_totals, :observations, 0) || 0
    }
  end

  defp collect_memory_issues(
         worker_status,
         dlq_summary,
         message_status_counts,
         stuck_count,
         pending_summary
       ) do
    issues = []

    issues =
      if Map.get(worker_status, :stale?, false) do
        [
          %{
            severity: "critical",
            code: "WORKER_STALE",
            message: "Extraction worker has not run recently",
            details: worker_status
          }
          | issues
        ]
      else
        issues
      end

    issues =
      if (Map.get(dlq_summary, :recent_hour, 0) || 0) > 10 do
        [
          %{
            severity: "critical",
            code: "DLQ_SURGE",
            message: "High number of DLQ entries in the last hour",
            details: %{recent_hour: Map.get(dlq_summary, :recent_hour, 0)}
          }
          | issues
        ]
      else
        issues
      end

    issues =
      if stuck_count > 0 do
        [
          %{
            severity: "critical",
            code: "STUCK_MESSAGES",
            message: "#{stuck_count} messages stuck in classified state",
            details: %{count: stuck_count}
          }
          | issues
        ]
      else
        issues
      end

    issues =
      if (Map.get(message_status_counts, "failed", 0) || 0) > 10 do
        [
          %{
            severity: "warning",
            code: "HIGH_FAILURE_RATE",
            message: "High message failure rate",
            details: %{failed_count: Map.get(message_status_counts, "failed", 0)}
          }
          | issues
        ]
      else
        issues
      end

    issues =
      if (Map.get(dlq_summary, :total, 0) || 0) > 0 and
           (Map.get(dlq_summary, :recent_hour, 0) || 0) <= 10 do
        [
          %{
            severity: "warning",
            code: "DLQ_HAS_ENTRIES",
            message: "DLQ has entries that need attention",
            details: %{total: Map.get(dlq_summary, :total, 0)}
          }
          | issues
        ]
      else
        issues
      end

    issues =
      if (Map.get(pending_summary, :overdue_count, 0) || 0) > 0 do
        [
          %{
            severity: "info",
            code: "OVERDUE_PENDING",
            message: "Some pending items are overdue",
            details: %{overdue_count: Map.get(pending_summary, :overdue_count, 0)}
          }
          | issues
        ]
      else
        issues
      end

    issues
  end

  defp collect_log_db_stats do
    # Log DB stats are best-effort — rescue silently if table doesn't exist yet
    try do
      %{
        total: count_logs(),
        errors_24h: count_logs(level: "error", since: hours_ago(24)),
        warnings_24h: count_logs(level: "warning", since: hours_ago(24)),
        clusters: count_log_clusters()
      }
    rescue
      _ -> %{total: 0, errors_24h: 0, warnings_24h: 0, clusters: []}
    end
  end

  defp count_logs(filters \\ []) do
    Acs.Log.LogRepo.count(filters)
  end

  defp count_log_clusters do
    try do
      import Ecto.Query

      Acs.Log.LogEntry
      |> group_by(:cluster)
      |> select([e], %{cluster: e.cluster, count: count(e.id)})
      |> Acs.Repo.all()
    rescue
      _ -> []
    end
  end

  defp hours_ago(n), do: DateTime.add(DateTime.utc_now(), -n * 3600, :second)

  defp extension_module do
    Application.get_env(
      :steward_acs,
      :app_extension,
      Acs.MCP.Tools.AppExtension.Default
    )
  end
end
