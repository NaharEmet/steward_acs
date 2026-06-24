defmodule Acs.MCP.Tools do
  @moduledoc "MCP Tool definitions and implementations for Acs."
  alias Acs.MCP.Tools.AnanthaQuery
  alias Acs.MCP.Tools.CoreHandlers
  alias Acs.MCP.Tools.DynamicTools
  alias Acs.MCP.Tools.MemoryHandlers
  alias Acs.MCP.Tools.ErrorHandlers
  alias Acs.MCP.Tools.DiagnosticHandlers
  alias Acs.MCP.Tools.ClusterHandlers
  require Logger

  def list_tools do
    [
      tool_def(
        "claim_work",
        "Claim a task for an agent. Returns task status, task_id, and a guidance packet with relevant knowledge memory for context. Optionally pass scope_path for targeted guidance.",
        %{
          "agent_id" => %{"type" => "string"},
          "task_id" => %{"type" => "string"},
          "scope_path" => %{
            "type" => "string",
            "description" =>
              "Optional scope path to generate guidance for (e.g. agent_coordination_system/cache). If provided, returns targeted knowledge memories for this scope."
          },
          "application" => %{"type" => "string"},
          "component" => %{"type" => "string"}
        },
        ["agent_id", "task_id"]
      ),
      tool_def(
        "release_work",
        "Release a task lock and get a structured feedback prompt with a next_step tool template. The response tells you exactly what to call (submit_task_feedback) with params to submit learnings as knowledge memories.",
        %{
          "agent_id" => %{"type" => "string"},
          "task_id" => %{"type" => "string"}
        },
        ["agent_id", "task_id"]
      ),
      tool_def(
        "create_work",
        "Create a new task with warnings about similar tasks, and optionally lock files",
        %{
          "agent_id" => %{"type" => "string"},
          "title" => %{"type" => "string"},
          "description" => %{"type" => "string"},
          "file_paths" => %{"type" => "array", "items" => %{"type" => "string"}},
          "application" => %{"type" => "string"},
          "component" => %{"type" => "string"}
        },
        ["agent_id", "title"]
      ),
      tool_def(
        "lock_file",
        "Lock a single file",
        %{
          "agent_id" => %{"type" => "string"},
          "task_id" => %{"type" => "string"},
          "file_path" => %{"type" => "string"}
        },
        ["agent_id", "task_id", "file_path"]
      ),
      tool_def(
        "unlock_file",
        "Unlock a file. Provide file_path to unlock a single file, or task_id to unlock all files for a task.",
        %{
          "agent_id" => %{"type" => "string"},
          "task_id" => %{
            "type" => "string",
            "description" => "Task ID to unlock all files for (alternative to file_path)"
          },
          "file_path" => %{"type" => "string"}
        },
        ["agent_id"]
      ),
      tool_def(
        "get_present_status",
        "Get current status of all agents. Use status_filter='sleeping' to list sleeping agents.",
        %{
          "agent_id" => %{"type" => "string"},
          "status_filter" => %{
            "type" => "string",
            "description" => "Set to 'sleeping' to list sleeping agents"
          }
        },
        []
      ),
      tool_def(
        "get_locked_files",
        "Get all currently locked files",
        %{},
        []
      ),
      tool_def(
        "list_tasks",
        "List all tasks",
        %{
          "agent_id" => %{"type" => "string"},
          "status_filter" => %{"type" => "string"}
        },
        ["agent_id"]
      ),
      tool_def(
        "sleep",
        "Put the calling agent to sleep until a task is created. " <>
          "The agent blocks (long-poll) until a task is dispatched, then wakes with a task_id. " <>
          "Call claim_work to claim the task. Returns immediately if a pending task exists.",
        %{
          "agent_id" => %{"type" => "string"},
          "timeout" => %{
            "type" => "integer",
            "description" =>
              "Max sleep time in milliseconds (default: 300000 = 5 min, 0 = infinite)"
          }
        },
        ["agent_id"]
      ),
      tool_def(
        "wake",
        "Manually wake a sleeping agent by sending a cancellation.",
        %{
          "agent_id" => %{"type" => "string"}
        },
        ["agent_id"]
      ),
      tool_def(
        "get_logs",
        "Retrieve application logs with optional filtering. Supports mode='list' (default, paginated results with filtered_total and total), mode='summary' (aggregated stats by level + top components + recent errors), or mode='errors_with_context' (error entries with surrounding context from full log timeline). Use compact=true for abbreviated output.",
        %{
          "level" => %{
            "type" => "string",
            "description" => "Minimum level: debug, info, warning, error"
          },
          "component" => %{
            "type" => "string",
            "description" => "Exact component (e.g. Acs::Acs::Cache)"
          },
          "module" => %{
            "type" => "string",
            "description" => "Partial match on module path (e.g. Acs, Cache)"
          },
          "search" => %{
            "type" => "string",
            "description" => "Substring match in message text (case-insensitive)"
          },
          "action" => %{
            "type" => "string",
            "description" => "Exact match on structured action field"
          },
          "tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Filter by tags (AND logic)"
          },
          "workflow_id" => %{"type" => "string"},
          "execution_id" => %{"type" => "string"},
          "since" => %{"type" => "string", "description" => "ISO8601 start time"},
          "until" => %{"type" => "string", "description" => "ISO8601 end time"},
          "limit" => %{"type" => "integer", "description" => "Max results (default: 100)"},
          "offset" => %{
            "type" => "integer",
            "description" => "Number of matching entries to skip (default: 0)"
          },
          "compact" => %{
            "type" => "boolean",
            "description" => "Return compact format (fewer tokens)"
          },
          "before_id" => %{
            "type" => "integer",
            "description" => "Cursor: get entries before this ID"
          },
          "after_id" => %{
            "type" => "integer",
            "description" => "Cursor: get entries after this ID"
          },
          "mode" => %{"type" => "string", "enum" => ["list", "summary", "errors_with_context"]},
          "context_size" => %{
            "type" => "integer",
            "description" => "Context lines before error (mode: errors_with_context)"
          }
        },
        []
      ),
      tool_def(
        "list_orgs",
        "List all organizations",
        %{},
        []
      ),
      tool_def(
        "time",
        "Get or set ACS time offset. Use action='get' to view current time info, action='set' with seconds to adjust the time offset.",
        %{
          "action" => %{
            "type" => "string",
            "description" => "Action: 'get' (view time info) or 'set' (set time offset)"
          },
          "seconds" => %{
            "type" => "integer",
            "description" => "Time offset in seconds (required when action='set')"
          }
        },
        ["action"]
      ),
      # Memory System Tools
      tool_def(
        "save_memory",
        "Create a new proposed memory entry. Memories are ETERNAL TRUTHS — principles, invariants, or axioms that remain true and useful indefinitely. NOT events, not historical facts, not one-time occurrences. USE WHEN: you discover something that will stay relevant — a reusable learning, decision, pattern, invariant, or truth that other agents should know about forever. After completing significant work, save key insights so the collective knowledge grows. Returns proposed memory id and any conflict flags.\n\nExamples of GOOD memory topics:\n- \"LiveViews subscribing to PubSub must have catch-all handle_info to avoid crashes from unhandled messages\"\n- \"The ACS loader extracts and indexes semantic content; it does NOT parse structural relationships\"\n- \"DynamicSupervisor children must have unique names or identical child specs will conflict\"\n\nExamples of BAD memory topics (these are EVENTS, not eternal truths):\n- \"Fixed GenServer crashes in 3 ACS LiveViews\" (this is what you DID, not what you LEARNED)\n- \"Updated the memory schema on 2024-01-15\" (historical fact, will become stale)\n- \"Added new save_memory endpoint\" (one-time event, not a reusable principle)\n\nThe 'kind' field (e.g., observation, learning, warning, pattern, bug, decision, invariant, axiom) describes the TYPE of learning, but the CONTENT must always be an eternal truth or principle.",
        %{
          "kind" => %{
            "type" => "string",
            "description" =>
              "Memory kind: observation, learning, warning, pattern, bug, decision, invariant, axiom"
          },
          "title" => %{"type" => "string", "description" => "Title of the memory"},
          "content" => %{
            "type" => "string",
            "description" => "Full markdown content of the memory"
          },
          "scope_path" => %{
            "type" => "string",
            "description" => "Scope path (e.g. agent_coordination_system/cache)"
          },
          "tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Tags for categorization"
          },
          "triggers" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Trigger events"
          },
          "importance" => %{
            "type" => "integer",
            "description" => "Importance 1-5"
          },
          "summary" => %{"type" => "string", "description" => "Brief summary"},
          "failure_modes" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Potential failure modes"
          }
        },
        ["kind", "title", "content", "scope_path"]
      ),
      tool_def(
        "list_memories",
        "List memories with optional filters by scope_path, kind, or status. USE WHEN: browsing what knowledge exists for a component, or checking the status of previously proposed memories.",
        %{
          "scope_path" => %{
            "type" => "string",
            "description" => "Filter by scope path prefix"
          },
          "kind" => %{"type" => "string", "description" => "Filter by kind"},
          "status" => %{
            "type" => "string",
            "description" =>
              "Filter by status: proposed, approved, rejected, stale, deprecated, archived"
          },
          "limit" => %{"type" => "integer", "description" => "Max results"}
        },
        []
      ),
      tool_def(
        "search_memories",
        "Full-text search across memory titles, summaries, and content. USE WHEN: starting a task that might have prior art, or when you need to check if something has been tried before. Essential for avoiding repeated mistakes.",
        %{
          "query" => %{"type" => "string", "description" => "Search query text"},
          "scope" => %{"type" => "string", "description" => "Optional scope filter"},
          "kind" => %{"type" => "string", "description" => "Optional kind filter"},
          "limit" => %{"type" => "integer", "description" => "Max results"}
        },
        ["query"]
      ),
      tool_def(
        "set_memory_status",
        "Update a memory's status (approved/rejected/stale/deprecated). Approving makes it visible to agents. Rejecting prevents it from being used. Marking stale flags it for review. Marking deprecated retires obsolete entries.",
        %{
          "memory_id" => %{"type" => "string", "description" => "Memory ID to update"},
          "status" => %{
            "type" => "string",
            "description" => "New status: approved, rejected, stale, or deprecated"
          },
          "notes" => %{
            "type" => "string",
            "description" => "Optional notes or reason for the status change"
          }
        },
        ["memory_id", "status"]
      ),
      tool_def(
        "generate_guidance_packet",
        "Generate a guidance packet for a scope path. Returns critical axioms, warnings, patterns, and compressed knowledge for agent context injection. USE WHEN: starting work on a new scope path to get context-specific guidance. This is the primary way to inject organizational memory into your task context.",
        %{
          "scope_path" => %{
            "type" => "string",
            "description" => "Scope path to generate guidance for"
          },
          "task_id" => %{
            "type" => "string",
            "description" => "Optional task ID to derive scope from"
          }
        },
        []
      ),
      # Error Trace Tools
      tool_def(
        "list_error_traces",
        "Find recurring errors that have been logged by the system. Each trace shows an error pattern, how many times it occurred, and when it was last seen.",
        %{
          "status" => %{
            "type" => "string",
            "description" => "Filter by status: new, acknowledged, resolved, tasked, failed"
          },
          "service" => %{"type" => "string", "description" => "Filter by service name"},
          "component" => %{"type" => "string", "description" => "Filter by component name"},
          "min_count" => %{"type" => "integer", "description" => "Minimum occurrence count"},
          "limit" => %{"type" => "integer", "description" => "Max results (default: 50)"}
        },
        []
      ),
      tool_def(
        "ack_error_trace",
        "Mark an error as 'in progress' so other agents know someone is already looking into it.",
        %{
          "trace_id" => %{"type" => "string", "description" => "Error trace ID to acknowledge"}
        },
        ["trace_id"]
      ),
      tool_def(
        "resolve_error_trace",
        "Mark an error as fixed/closed after the issue has been investigated and resolved.",
        %{
          "trace_id" => %{"type" => "string", "description" => "Error trace ID to resolve"}
        },
        ["trace_id"]
      ),
      tool_def(
        "create_task_from_error_trace",
        "Turn an error trace into a task that an agent can claim and fix. The error is marked as 'tasked' to avoid duplicate work.",
        %{
          "trace_id" => %{"type" => "string", "description" => "Error trace ID"},
          "agent_id" => %{
            "type" => "string",
            "description" => "Agent to assign the task to (default: error_trace_system)"
          }
        },
        ["trace_id"]
      ),
      # Task Completion Feedback
      tool_def(
        "submit_task_feedback",
        "Submit task feedback that auto-generates knowledge memories from your learnings. Use after completing a task to share discoveries with future agents.",
        %{
          "task_id" => %{"type" => "string", "description" => "The completed task ID"},
          "learned_for_agents" => %{
            "type" => "string",
            "description" => "What did you learn that will help agents in the future?"
          },
          "had_issues" => %{
            "type" => "string",
            "description" => "What issues or obstacles did you encounter?"
          },
          "improvements" => %{
            "type" => "string",
            "description" => "What could have made this task easier?"
          },
          "tools_wish_list" => %{
            "type" => "string",
            "description" => "What tools or capabilities would make future tasks easier?"
          },
          "info_needed" => %{
            "type" => "string",
            "description" => "What information was hard to find during this task?"
          },
          "guidance_useful" => %{
            "type" => "boolean",
            "description" => "Was the guidance packet useful for this task?"
          },
          "guidance_items_helpful" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Memory IDs from the guidance packet that were helpful"
          },
          "guidance_items_confusing" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "Memory IDs from the guidance packet that were confusing or unhelpful"
          },
          "guidance_missing" => %{
            "type" => "string",
            "description" => "What guidance was needed but missing from the packet?"
          }
        },
        ["task_id"]
      ),
      tool_def(
        "help",
        "Returns a comprehensive reference of all available MCP tools with their levels, categories, and descriptions. Use this to discover what tools exist and how to access them. Unlike the default tool listing (which only shows level 1), this queries all tools directly and shows their true access levels.",
        %{
          "category" => %{
            "type" => "string",
            "description" =>
              "Filter tools by category (e.g., 'acs_core', 'knowledge', 'cognition')"
          },
          "level" => %{
            "type" => "integer",
            "description" =>
              "Filter: show tools at this level and below (progressive disclosure). Default: shows all levels."
          }
        },
        []
      ),
      tool_def(
        "query",
        "Query ACS telemetry data. Use for analysis, debugging, and generating insights.",
        %{
          "sql" => %{"type" => "string", "description" => "SQL query against ACS data"},
          "purpose" => %{"type" => "string", "description" => "What you're trying to find"}
        },
        ["sql"]
      ),
      tool_def(
        "config_lookup",
        "Look up opencode configuration settings. Returns agent config, skills, plugins, and MCP server settings.",
        %{
          "path" => %{"type" => "string", "description" => "Config path to look up (e.g. 'agents', 'skills', 'plugins', 'mcp')"},
          "key" => %{"type" => "string", "description" => "Specific key to retrieve (optional)"}
        },
        []
      ),
      tool_def(
        "connection_diagnostic",
        "Check if external services (ACS, database, LLM providers) are reachable. Returns connectivity status for each service.",
        %{
          "service" => %{"type" => "string", "description" => "Specific service to check: 'acs', 'database', 'llm', or 'all' (default)"},
          "verbose" => %{"type" => "boolean", "description" => "Include detailed error info (default: false)"}
        },
        []
      ),
      tool_def(
        "find_similar_code",
        "Semantic search across the codebase for similar code patterns. Uses embeddings to find semantically similar code.",
        %{
          "query" => %{"type" => "string", "description" => "Code snippet or description to search for"},
          "limit" => %{"type" => "integer", "description" => "Max results to return (default: 5)"},
          "scope" => %{"type" => "string", "description" => "Scope path to limit search (optional)"}
        },
        ["query"]
      ),
      tool_def(
        "memory_health_check",
        "Check the health status of the Anantha memory system. Returns overall health score, pipeline status, DLQ metrics, data flow statistics, and any issues detected. Use this to verify data has been added correctly and identify problems. Specify org_id to filter by organization, or omit for global view.",
        %{
          "org_id" => %{"type" => "string", "description" => "Optional org ID to scope the health check to a specific organization"}
        },
        []
      ),

    ]
  end

  defp tool_def(name, desc, props, required) do
    %{
      "name" => name,
      "description" => desc,
      "inputSchema" => %{"type" => "object", "properties" => props, "required" => required}
    }
  end

  @simple_dispatch %{
    "claim_work" => &CoreHandlers.acs_claim_work/1,
    "release_work" => &CoreHandlers.acs_release_work/1,
    "create_work" => &CoreHandlers.acs_create_work/1,
    "lock_file" => &CoreHandlers.acs_lock_file/1,
    "unlock_file" => &CoreHandlers.acs_unlock_file/1,
    "get_present_status" => &CoreHandlers.acs_get_present_status/1,
    "get_locked_files" => &CoreHandlers.acs_get_locked_files/1,
    "list_tasks" => &CoreHandlers.acs_list_tasks/1,
    "sleep" => &CoreHandlers.acs_sleep/1,
    "wake" => &CoreHandlers.acs_wake/1,
    "get_logs" => &CoreHandlers.get_logs/1,
    "list_orgs" => &CoreHandlers.list_orgs/1,
    "time" => &CoreHandlers.acs_time/1,
    "save_memory" => &MemoryHandlers.save_memory/1,
    "list_memories" => &MemoryHandlers.list_memories/1,
    "search_memories" => &MemoryHandlers.search_memories/1,
    "set_memory_status" => &MemoryHandlers.set_memory_status/1,
    "generate_guidance_packet" => &MemoryHandlers.generate_guidance_packet/1,
    "list_error_traces" => &ErrorHandlers.list_error_traces/1,
    "ack_error_trace" => &ErrorHandlers.ack_error_trace/1,
    "resolve_error_trace" => &ErrorHandlers.resolve_error_trace/1,
    "create_task_from_error_trace" => &ErrorHandlers.create_task_from_error_trace/1,
    "submit_task_feedback" => &ErrorHandlers.acs_submit_task_feedback/1,
    "help" => &DiagnosticHandlers.acs_help/1,
    "query" => &DiagnosticHandlers.acs_query/1,
    "config_lookup" => &DiagnosticHandlers.config_lookup/1,
    "connection_diagnostic" => &DiagnosticHandlers.connection_diagnostic/1,
    "find_similar_code" => &DiagnosticHandlers.find_similar_code/1,
    "memory_health_check" => &DiagnosticHandlers.memory_health_check/1,
    "exec_command" => &ClusterHandlers.exec_command/1,
    "read_file" => &ClusterHandlers.read_file/1,
    "write_file" => &ClusterHandlers.write_file/1,
    "read_dir" => &ClusterHandlers.read_dir/1
  }

  @gated_tools %{
    "anantha_search_memory" => &AnanthaQuery.search_memory/1,
    "anantha_get_synthesis" => &AnanthaQuery.get_synthesis/1,
    "ant_get_claim" => &AnanthaQuery.get_claim/1,
    "ant_get_observation" => &AnanthaQuery.get_observation/1,
    "anantha_get_source_excerpt" => &AnanthaQuery.get_source_excerpt/1,
    "anantha_get_entity" => &AnanthaQuery.get_entity/1,
    "anantha_execute_query" => &AnanthaQuery.execute_query/1,
    "anantha_export_dataset" => &AnanthaQuery.export_dataset/1,
    "anantha_drilldown" => &AnanthaQuery.drilldown/1
  }

  defp dispatch_map do
    # Tools needing closures (partial application) built at runtime
    %{
      "write_tool" => &DynamicTools.call_tool("write_tool", &1)
    }
  end

  def call_tool(name, args) do
    Logger.info("MCP tool: #{name} - #{tool_action_summary(name, args)}")

    if agent_id = Map.get(args, "agent_id") do
      case Acs.Acs.Cache.get_agent_status(agent_id) do
        {:ok, nil} ->
          Acs.Acs.Cache.put_agent_status(agent_id, %{purpose: "active", current_task_id: nil, application: nil, component: nil})

        _ ->
          Acs.Acs.Cache.touch_agent_status(agent_id)
      end
    end

    result =
      case Map.fetch(@simple_dispatch, name) do
        {:ok, fun} ->
          fun.(args)

        :error ->
          case Map.fetch(dispatch_map(), name) do
            {:ok, fun} ->
              fun.(args)

            :error ->
              case Map.fetch(@gated_tools, name) do
                {:ok, fun} ->
                  if anantha_tools_enabled?() do
                    fun.(args)
                  else
                    {:error, "Anantha tools not enabled. Set config :steward_acs, :anantha_tools_enabled, true"}
                  end

                :error ->
                  {:error, "Unknown tool: #{name}"}
          end
        end
      end

    Logger.info("MCP tool response: #{name} - #{tool_response_summary(name, result)}")
    result
  end

  defp tool_response_summary(_name, {:ok, result}) when is_map(result) do
    keys = Map.keys(result) |> Enum.join(", ")
    "ok (keys: #{keys})"
  end

  defp tool_response_summary(_name, {:ok, result}), do: "ok: #{inspect(result)}"
  defp tool_response_summary(_name, {:error, reason}), do: "error: #{inspect(reason)}"
  defp tool_response_summary(_name, :ok), do: "ok"

  defp tool_response_summary("sleep", {:sleep, agent_id, _timeout}),
    do: "sleep: agent=#{agent_id}"

  defp tool_action_summary("claim_work", %{"task_id" => task_id, "agent_id" => agent_id}),
    do: "claim task=#{task_id} for agent=#{agent_id}"

  defp tool_action_summary("release_work", %{"task_id" => task_id, "agent_id" => agent_id}),
    do: "release task=#{task_id} for agent=#{agent_id}"

  defp tool_action_summary("create_work", %{"title" => title, "agent_id" => agent_id}),
    do: "create task '#{title}' for agent=#{agent_id}"

  defp tool_action_summary("lock_file", %{"file_path" => path, "agent_id" => agent_id}),
    do: "lock file=#{path} for agent=#{agent_id}"

  defp tool_action_summary("unlock_file", %{"file_path" => path, "agent_id" => agent_id}),
    do: "unlock file=#{path} for agent=#{agent_id}"

  defp tool_action_summary("unlock_file", %{"task_id" => task_id, "agent_id" => agent_id}),
    do: "unlock all files for task=#{task_id} agent=#{agent_id}"

  defp tool_action_summary("get_present_status", %{"agent_id" => agent_id}),
    do: "get status for agent=#{agent_id}"

  defp tool_action_summary("get_present_status", %{"status_filter" => "sleeping"}),
    do: "list sleeping agents"

  defp tool_action_summary("get_locked_files", _),
    do: "get all locked files"

  defp tool_action_summary("list_tasks", %{"agent_id" => agent_id, "status_filter" => status}),
    do: "list tasks for agent=#{agent_id} filter=#{status}"

  defp tool_action_summary("sleep", %{"agent_id" => agent_id}),
    do: "sleep agent=#{agent_id}"

  defp tool_action_summary("wake", %{"agent_id" => agent_id}),
    do: "wake agent=#{agent_id}"

  defp tool_action_summary("get_logs", args),
    do: "get logs (mode=#{Map.get(args, "mode", "list")}, filters: #{map_size(args)} params)"

  defp tool_action_summary("list_orgs", _args),
    do: "list all orgs"

  defp tool_action_summary("time", %{"action" => "get"}),
    do: "get time info"

  defp tool_action_summary("time", %{"action" => "set", "seconds" => secs}),
    do: "set time offset=#{secs}s"

  defp tool_action_summary("time", args),
    do: "time: #{inspect(args)}"

  defp tool_action_summary("save_memory", %{"title" => title}),
    do: "save memory: #{title}"

  defp tool_action_summary("list_memories", %{"scope_path" => scope}),
    do: "list memories for scope=#{scope}"

  defp tool_action_summary("list_memories", args),
    do: "list memories: #{inspect(args)}"

  defp tool_action_summary("search_memories", %{"query" => query}),
    do: "search memories: #{query}"

  defp tool_action_summary("set_memory_status", %{"memory_id" => id, "status" => status}),
    do: "set memory #{id} status=#{status}"

  defp tool_action_summary("generate_guidance_packet", %{"scope_path" => scope}),
    do: "generate guidance for scope=#{scope}"

  defp tool_action_summary("generate_guidance_packet", %{"task_id" => task_id}),
    do: "generate guidance for task=#{task_id}"

  defp tool_action_summary("generate_guidance_packet", args),
    do: "generate guidance: #{inspect(args)}"

  defp tool_action_summary("write_tool", %{"name" => name}),
    do: "write tool: #{name}"

  defp tool_action_summary("write_tool", _),
    do: "write tool"

  defp tool_action_summary("list_error_traces", args),
    do: "list error traces: #{inspect(args)}"

  defp tool_action_summary("ack_error_trace", %{"trace_id" => id}),
    do: "ack error trace: #{id}"

  defp tool_action_summary("resolve_error_trace", %{"trace_id" => id}),
    do: "resolve error trace: #{id}"

  defp tool_action_summary("create_task_from_error_trace", %{"trace_id" => id}),
    do: "create task from error trace: #{id}"

  defp tool_action_summary("submit_task_feedback", %{"task_id" => task_id}),
    do: "submit feedback for task=#{task_id}"

  # Anantha tools
  defp tool_action_summary("anantha_search_memory", %{"query" => query}),
    do: "search memory: #{query}"

  defp tool_action_summary("anantha_get_synthesis", %{"id" => id}),
    do: "get synthesis: #{id}"

  defp tool_action_summary("anantha_get_claim", %{"id" => id}),
    do: "get claim: #{id}"

  defp tool_action_summary("anantha_get_observation", %{"id" => id}),
    do: "get observation: #{id}"

  defp tool_action_summary("anantha_get_source_excerpt", %{"id" => id}),
    do: "get source excerpt: #{id}"

  defp tool_action_summary("anantha_get_entity", %{"id" => id}),
    do: "get entity: #{id}"

  defp tool_action_summary("anantha_execute_query", %{"dataset" => dataset}),
    do: "execute query on dataset: #{dataset}"

  defp tool_action_summary("anantha_export_dataset", %{"dataset" => dataset}),
    do: "export dataset: #{dataset}"

  defp tool_action_summary("anantha_drilldown", %{"query_id" => qid, "row_index" => idx}),
    do: "drilldown query=#{qid} row=#{idx}"

  # Cluster tools
  defp tool_action_summary("exec_command", %{"command" => cmd}),
    do: "exec: #{cmd}"

  defp tool_action_summary("read_file", %{"path" => path}),
    do: "read: #{path}"

  defp tool_action_summary("write_file", %{"path" => path}),
    do: "write: #{path}"

  defp tool_action_summary("read_dir", %{"path" => path}),
    do: "ls: #{path}"

  defp tool_action_summary("exec_command", _args), do: "exec command"
  defp tool_action_summary("read_file", _args), do: "read file"
  defp tool_action_summary("write_file", _args), do: "write file"
  defp tool_action_summary("read_dir", _args), do: "list dir"

  defp tool_action_summary(_name, _args), do: "called"

  defp anantha_tools_enabled? do
    Application.get_env(:steward_acs, :anantha_tools_enabled, false)
  end

end
