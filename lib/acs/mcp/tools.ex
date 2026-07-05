defmodule Acs.MCP.Tools do
  @moduledoc "MCP Tool definitions and implementations for Acs."
  alias Acs.MCP.Tools.CoreHandlers
  alias Acs.MCP.Tools.DynamicTools
  alias Acs.MCP.Tools.MemoryHandlers
  alias Acs.MCP.Tools.ErrorHandlers
  alias Acs.MCP.Tools.DiagnosticHandlers
  alias Acs.MCP.Tools.SkillHandlers
  alias Acs.MCP.Tools.QueryAgent
  require Logger

  @tool_categories %{
    # ACS Core (workflow) tools
    "claim_work" => "acs_core",
    "release_work" => "acs_core",
    "create_work" => "acs_core",
    "lock_file" => "acs_core",
    "unlock_file" => "acs_core",
    "get_present_status" => "acs_core",
    "get_locked_files" => "acs_core",
    "list_tasks" => "acs_core",
    "time" => "acs_core",
    "get_logs" => "acs_core",
    "list_orgs" => "acs_core",
    "list_plugins" => "acs_core",
    "app_list" => "acs_core",
    "app_configure" => "acs_core",
    "app_remove" => "acs_core",
    "write_tool" => "acs_core",
    # Knowledge (memory) tools
    "save_memory" => "knowledge",
    "query_memories" => "knowledge",
    "set_memory_status" => "knowledge",
    "generate_guidance_packet" => "knowledge",
    "ask" => "knowledge",
    # Specs tools
    "specs_get" => "specs",
    "query_specs" => "specs",
    "specs_propose" => "specs",
    "specs_approve" => "specs",
    "specs_reject" => "specs",
    # Diagnostic tools
    "help" => "diagnostic",
    "query" => "diagnostic",
    "config_lookup" => "diagnostic",
    "connection_diagnostic" => "diagnostic",
    "memory_health_check" => "diagnostic",
    # Error tools
    "list_error_traces" => "error",
    "ack_error_trace" => "error",
    "resolve_error_trace" => "error",
    "create_task_from_error_trace" => "error",
    "submit_task_feedback" => "error",
    # Skill tools
    "skill_get" => "skills",
    "skill_save" => "skills",
    "skill_audit_status" => "skills"
  }

  def tool_category(name) do
    Map.get(@tool_categories, name)
  end

  def list_tools do
    [
      tool_def(
        "claim_work",
        "Claim a task for an agent. Returns task status, task_id, and a guidance packet with relevant knowledge memory for context. Optionally pass scope_path for targeted guidance.",
        %{
          "agent_id" => %{
            "type" => "string",
            "description" =>
              "Your team member name (e.g., 'alice'). Used as your identity in the ACS."
          },
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
          "agent_id" => %{"type" => "string", "description" => "Your team member name."},
          "task_id" => %{"type" => "string"}
        },
        ["agent_id", "task_id"]
      ),
      tool_def(
        "create_work",
        "Create a new task. Set claim=true to immediately claim it (sets status to in_progress and locks it to you). Without claim, the task is created as todo and dispatched to a sleeping agent if available.",
        %{
          "agent_id" => %{
            "type" => "string",
            "description" => "Your team member name who creates this task."
          },
          "title" => %{"type" => "string"},
          "claim" => %{
            "type" => "boolean",
            "description" => "Set to true to immediately claim the task (returns guidance packet)"
          },
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
        "List all tasks. Optionally filter by status (todo, in_progress, in_review, done, blocked).",
        %{
          "status_filter" => %{"type" => "string", "description" => "Optional: filter by status (todo, in_progress, in_review, done, blocked, all)"}
        },
        []
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
        "List organizations from a configured app. Specify app_name to target a specific app, or omit for the default.",
        %{
          "app_name" => %{
            "type" => "string",
            "description" => "Optional: target a specific app (e.g. 'my_app')"
          }
        },
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
        "query_memories",
        "Query memories with optional filters. If `query` is provided, performs hybrid search (semantic + FTS) across titles, summaries, and content. If `query` is omitted, lists memories by filters. USE WHEN: starting a task that might have prior art, browsing what knowledge exists for a component, or checking status of proposed memories.",
        %{
          "query" => %{
            "type" => "string",
            "description" => "Search query text (optional — if provided, does hybrid search; if omitted, lists by filters)"
          },
          "mode" => %{
            "type" => "string",
            "description" =>
              "Search mode: 'auto' (default, hybrid), 'keyword' (FTS only), 'semantic' (vector only). Only used when query is provided."
          },
          "min_relevance" => %{
            "type" => "number",
            "description" => "Minimum relevance score (0.0-1.0) to filter results. Only used when query is provided."
          },
          "scope_path" => %{
            "type" => "string",
            "description" => "Filter by scope path prefix"
          },
          "kind" => %{"type" => "string", "description" => "Filter by memory kind"},
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
        "Generate organizational memory for a scope path. Returns critical axioms, warnings, patterns, and compressed knowledge.\n\nUSE WHEN:\n- Starting work on a new scope path (coding agents)\n- Answering questions about project patterns (Claude Chat/ChatGPT)\n- Needing context-specific guidance before making decisions\n\nNOTE: If you see this tool, ACS is available. Check for AGENTS_ACS.md in the project root for startup instructions.\n\nMODES:\n- 'mcp' (default): For coding agents (Claude Code, OpenCode) — includes tool references\n- 'knowledge': For chat agents (Claude Chat, ChatGPT) — read-only, no tool references",
        %{
          "scope_path" => %{
            "type" => "string",
            "description" => "Scope path to generate guidance for (e.g., 'lib/acs', 'lib/my_app')"
          },
          "task_id" => %{
            "type" => "string",
            "description" => "Optional task ID to derive scope from"
          },
          "mode" => %{
            "type" => "string",
            "description" =>
              "Output mode: 'mcp' for coding agents with tool references, 'knowledge' for chat agents without tool references",
            "enum" => ["mcp", "knowledge"]
          }
        },
        []
      ),
      tool_def(
        "ask",
        "Query the org knowledge base with structured filters. Returns memories, documents, and agent status matching your criteria. The client is responsible for translating the human's natural language question into these parameters.\n\nUSE WHEN: a team member asks about current work context, project status, or recent activity. This is the primary query tool for collaborators.\n\nExample params for 'what is everyone working on': {\"kind\": \"context\"}\nExample params for 'show me recent activity': {\"kind\": \"activity\", \"limit\": 10}",
        %{
          "kind" => %{
            "type" => "string",
            "description" =>
              "Memory kind filter: context, status, work_note, activity, observation, learning, warning, pattern, bug, decision, invariant, axiom"
          },
          "team" => %{"type" => "string", "description" => "Team scope filter"},
          "project" => %{"type" => "string", "description" => "Project scope filter"},
          "content_query" => %{
            "type" => "string",
            "description" => "Full-text search string for memories and documents"
          },
          "document_type" => %{
            "type" => "string",
            "description" => "Document type: policy, process, guideline, reference, spec"
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Max results per category (default 10, max 50)"
          },
          "include_documents" => %{
            "type" => "boolean",
            "description" => "Include documents in results (default true)"
          },
          "include_agent_status" => %{
            "type" => "boolean",
            "description" => "Include agent presence (default true)"
          }
        },
        []
      ),
      # Specs Tools
      tool_def(
        "specs_get",
        "Load a single spec entry by app and path. Specs contain structured documentation about modules.",
        %{
          "app" => %{"type" => "string", "description" => "App name (e.g., 'my_app')"},
          "path" => %{
            "type" => "string",
            "description" => "Spec path (e.g., 'engine/orchestrator')"
          }
        },
        ["app", "path"]
      ),
      tool_def(
        "query_specs",
        "Query specs: search, list, or find undocumented. If `query` is provided, does full-text search. If `undocumented` is true, finds modules missing specs. Otherwise lists specs with optional filters.",
        %{
          "query" => %{"type" => "string", "description" => "Search query text (optional)"},
          "app" => %{"type" => "string", "description" => "Optional app filter"},
          "status" => %{"type" => "string", "description" => "Optional status filter"},
          "undocumented" => %{
            "type" => "boolean",
            "description" => "Set to true to find modules without spec entries"
          },
          "limit" => %{"type" => "integer", "description" => "Max results"}
        },
        []
      ),
      tool_def(
        "specs_propose",
        "Create or update a spec entry. Sets status to 'proposed'. Includes deduplication warnings for similar entries.",
        %{
          "app" => %{"type" => "string", "description" => "App name"},
          "path" => %{"type" => "string", "description" => "Spec path"},
          "title" => %{"type" => "string", "description" => "Human-readable title"},
          "purpose" => %{"type" => "string", "description" => "Why this module exists"},
          "content" => %{"type" => "string", "description" => "Full spec content"}
        },
        ["app", "path"]
      ),
      tool_def(
        "specs_approve",
        "Approve a proposed spec entry. Sets status to 'approved'.",
        %{
          "app" => %{"type" => "string", "description" => "App name"},
          "path" => %{"type" => "string", "description" => "Spec path"},
          "reviewer" => %{"type" => "string", "description" => "Reviewer identifier"}
        },
        ["app", "path", "reviewer"]
      ),
      tool_def(
        "specs_reject",
        "Soft-reject a spec entry. Reverts status to 'under_review'.",
        %{
          "app" => %{"type" => "string", "description" => "App name"},
          "path" => %{"type" => "string", "description" => "Spec path"}
        },
        ["app", "path"]
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
          "agent_id" => %{"type" => "string", "description" => "Your team member name (e.g., 'alice'). Used as your identity in the ACS."},
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
        ["task_id", "agent_id"]
      ),
      tool_def(
        "help",
        "Returns a comprehensive reference of all available MCP tools with their levels, categories, and descriptions. Use this to discover what tools exist and how to access them. Unlike the default tool listing (which only shows level 1), this queries all tools directly and shows their true access levels.",
        %{
          "category" => %{
            "type" => "string",
            "description" => "Filter tools by category (e.g., 'acs_core', 'knowledge', 'specs')"
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
        "Query ACS telemetry data with read-only SQL (SELECT, WITH, EXPLAIN). Aggregates allowed. No writes.",
        %{
          "sql" => %{
            "type" => "string",
            "description" => "Read-only SQL query (SELECT/WITH/EXPLAIN only)"
          },
          "purpose" => %{"type" => "string", "description" => "What you're trying to find"}
        },
        ["sql"]
      ),
      tool_def(
        "config_lookup",
        "Look up opencode configuration settings. Returns agent config, skills, plugins, and MCP server settings.",
        %{
          "path" => %{
            "type" => "string",
            "description" => "Config path to look up (e.g. 'agents', 'skills', 'plugins', 'mcp')"
          },
          "key" => %{"type" => "string", "description" => "Specific key to retrieve (optional)"}
        },
        []
      ),
      tool_def(
        "connection_diagnostic",
        "Check if external services (ACS, database, LLM providers) are reachable. Returns connectivity status for each service.",
        %{
          "service" => %{
            "type" => "string",
            "description" =>
              "Specific service to check: 'acs', 'database', 'llm', or 'all' (default)"
          },
          "verbose" => %{
            "type" => "boolean",
            "description" => "Include detailed error info (default: false)"
          }
        },
        []
      ),
      tool_def(
        "memory_health_check",
        "Check the health status of the Anantha memory system. Returns overall health score, pipeline status, DLQ metrics, data flow statistics, and any issues detected. Use this to verify data has been added correctly and identify problems. Specify org_id to filter by organization, or omit for global view.",
        %{
          "org_id" => %{
            "type" => "string",
            "description" =>
              "Optional org ID to scope the health check to a specific organization"
          }
        },
        []
      ),
      tool_def(
        "list_plugins",
        "List all registered plugin apps with their metadata, tool counts, and health status. Returns app name, version, plugin source info, and tools provided by each plugin.",
        %{},
        []
      ),
      tool_def(
        "app_list",
        "List all configured external apps with their base URL, auth status, and endpoint info.",
        %{},
        []
      ),
      tool_def(
        "app_configure",
        "Add or update a configured external app at runtime.",
        %{
          "name" => %{"type" => "string", "description" => "App name (e.g. 'my_app')"},
          "base_url" => %{"type" => "string", "description" => "Root URL of the app"},
          "api_key" => %{
            "type" => "string",
            "description" => "API key for authenticating with the app"
          },
          "auth_endpoint" => %{
            "type" => "string",
            "description" => "Auth validation endpoint path (default: /api/auth/validate-key)"
          },
          "auth_header_name" => %{
            "type" => "string",
            "description" => "HTTP header for API key (default: 'authorization')"
          },
          "auth_header_scheme" => %{
            "type" => "string",
            "description" =>
              "Auth scheme prefix, e.g. 'Bearer', or '' for raw key (default: 'Bearer')"
          },
          "timeout_ms" => %{
            "type" => "integer",
            "description" => "Request timeout in milliseconds (default: 30000)"
          }
        },
        ["name"]
      ),
      tool_def(
        "app_remove",
        "Remove a configured external app at runtime.",
        %{
          "name" => %{"type" => "string", "description" => "App name to remove"}
        },
        ["name"]
      ),
      tool_def(
        "skill_get",
        "Retrieve skills. Pass `name` to get one skill, `search` to search, `tag` to filter by tag, or nothing to list all.",
        %{
          "name" => %{
            "type" => "string",
            "description" => "Skill name to retrieve"
          },
          "search" => %{
            "type" => "string",
            "description" => "Search query across skill names, descriptions, tags, and content"
          },
          "tag" => %{
            "type" => "string",
            "description" => "Filter skills by tag"
          }
        },
        []
      ),
      tool_def(
        "skill_save",
        "Create or update a skill. Agents use this to store workflows, guides, and know-how for other agents.",
        %{
          "name" => %{
            "type" => "string",
            "description" => "Unique skill name (e.g. 'secrets-management')"
          },
          "content" => %{
            "type" => "string",
            "description" => "Skill body content (markdown)"
          },
          "tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Tags for categorization"
          },
          "description" => %{
            "type" => "string",
            "description" => "Short description of what this skill covers"
          }
        },
        ["name", "content"]
      ),
      tool_def(
        "skill_audit_status",
        "Run a quality audit on all skills and return results. Checks frontmatter completeness, content length, description quality, and tags.",
        %{},
        []
      )
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
    "get_logs" => &CoreHandlers.get_logs/1,
    "list_orgs" => &CoreHandlers.list_orgs/1,
    "time" => &CoreHandlers.acs_time/1,
    "save_memory" => &MemoryHandlers.save_memory/1,
    "query_memories" => &MemoryHandlers.query_memories/1,
    "set_memory_status" => &MemoryHandlers.set_memory_status/1,
    "generate_guidance_packet" => &MemoryHandlers.generate_guidance_packet/1,
    "ask" => &QueryAgent.ask/1,
    "list_error_traces" => &ErrorHandlers.list_error_traces/1,
    "ack_error_trace" => &ErrorHandlers.ack_error_trace/1,
    "resolve_error_trace" => &ErrorHandlers.resolve_error_trace/1,
    "create_task_from_error_trace" => &ErrorHandlers.create_task_from_error_trace/1,
    "submit_task_feedback" => &ErrorHandlers.acs_submit_task_feedback/1,
    "help" => &DiagnosticHandlers.acs_help/1,
    "query" => &DiagnosticHandlers.acs_query/1,
    "config_lookup" => &DiagnosticHandlers.config_lookup/1,
    "connection_diagnostic" => &DiagnosticHandlers.connection_diagnostic/1,
    "memory_health_check" => &DiagnosticHandlers.memory_health_check/1,
    "list_plugins" => &CoreHandlers.list_plugins/1,
    "app_list" => &CoreHandlers.app_list/1,
    "app_configure" => &CoreHandlers.app_configure/1,
    "app_remove" => &CoreHandlers.app_remove/1,
    "skill_get" => &SkillHandlers.skill_get/1,
    "skill_save" => &SkillHandlers.skill_save/1,
    "skill_audit_status" => &SkillHandlers.skill_audit_status/1
  }

  defp dispatch_map do
    # Tools needing closures (partial application) built at runtime
    %{
      "write_tool" => &DynamicTools.call_tool("write_tool", &1),
      "specs_get" => &Acs.Specs.Tools.call_tool("specs_get", &1),
      "query_specs" => &Acs.Specs.Tools.call_tool("query_specs", &1),
      "specs_propose" => &Acs.Specs.Tools.call_tool("specs_propose", &1),
      "specs_approve" => &Acs.Specs.Tools.call_tool("specs_approve", &1),
      "specs_reject" => &Acs.Specs.Tools.call_tool("specs_reject", &1)
    }
  end

  def call_tool(name, args) do
    Logger.info("MCP tool: #{name} - #{tool_action_summary(name, args)}")

    with :ok <- validate_agent_identity(args) do
      if agent_id = Map.get(args, "agent_id") do
        case Acs.Acs.Cache.get_agent_status(agent_id) do
          {:ok, nil} ->
            Acs.Acs.put_agent_status(agent_id, %{
              purpose: "active",
              current_task_id: nil
            })

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
                {:error, "Unknown tool: #{name}"}
            end
        end

      Logger.info("MCP tool response: #{name} - #{tool_response_summary(name, result)}")
      result
    end
  end

  defp validate_agent_identity(args) do
    requested = Map.get(args, "agent_id")
    auth_identity = Map.get(args, "_auth_agent_id")
    auth_role = Map.get(args, "_auth_role")

    cond do
      is_nil(requested) ->
        :ok

      auth_role == "admin" ->
        :ok

      is_nil(auth_identity) or auth_identity == "" ->
        {:error, "Authenticated agent identity is required"}

      normalize_agent_id(requested) == normalize_agent_id(auth_identity) ->
        :ok

      true ->
        {:error,
         "agent_id '#{requested}' does not match authenticated identity '#{auth_identity}'"}
    end
  end

  defp normalize_agent_id(id) when is_binary(id), do: String.downcase(String.trim(id))

  @doc """
  Returns true if the given tool name is registered in the core dispatch.
  Used by ToolRegistry.authorize_tool as a fallback for tools not in YAML definitions.
  """
  def has_tool?(name) do
    Map.has_key?(@simple_dispatch, name) or Map.has_key?(dispatch_map(), name)
  end

  defp tool_response_summary(_name, {:ok, result}) when is_map(result) do
    keys = Map.keys(result) |> Enum.join(", ")
    "ok (keys: #{keys})"
  end

  defp tool_response_summary(_name, {:ok, result}), do: "ok: #{inspect(result)}"
  defp tool_response_summary(_name, {:error, reason}), do: "error: #{inspect(reason)}"
  defp tool_response_summary(_name, :ok), do: "ok"

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

  defp tool_action_summary("get_logs", args),
    do: "get logs (mode=#{Map.get(args, "mode", "list")}, filters: #{map_size(args)} params)"

  defp tool_action_summary("list_orgs", args),
    do: "list orgs for app=#{Map.get(args, "app_name", "default")}"

  defp tool_action_summary("app_list", _args),
    do: "list configured apps"

  defp tool_action_summary("app_configure", %{"name" => name}),
    do: "configure app: #{name}"

  defp tool_action_summary("app_remove", %{"name" => name}),
    do: "remove app: #{name}"

  defp tool_action_summary("skill_get", %{"name" => name}),
    do: "get skill: #{name}"

  defp tool_action_summary("skill_get", %{"search" => query}),
    do: "search skills: #{query}"

  defp tool_action_summary("skill_get", %{"tag" => tag}),
    do: "list skills (tag=#{tag})"

  defp tool_action_summary("skill_get", _),
    do: "list all skills"

  defp tool_action_summary("skill_save", %{"name" => name}),
    do: "save skill: #{name}"

  defp tool_action_summary("skill_audit_status", _),
    do: "audit skills"

  defp tool_action_summary("time", %{"action" => "get"}),
    do: "get time info"

  defp tool_action_summary("time", %{"action" => "set", "seconds" => secs}),
    do: "set time offset=#{secs}s"

  defp tool_action_summary("time", args),
    do: "time: #{inspect(args)}"

  defp tool_action_summary("save_memory", %{"title" => title}),
    do: "save memory: #{title}"

  defp tool_action_summary("query_memories", %{"query" => query}),
    do: "search memories: #{query}"

  defp tool_action_summary("query_memories", %{"scope_path" => scope}),
    do: "list memories for scope=#{scope}"

  defp tool_action_summary("query_memories", args),
    do: "query memories: #{inspect(args)}"

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

  # Specs tools
  defp tool_action_summary("specs_get", %{"app" => app, "path" => path}),
    do: "specs_get: #{app}/#{path}"

  defp tool_action_summary("query_specs", %{"query" => query}),
    do: "query_specs search: #{query}"

  defp tool_action_summary("query_specs", %{"undocumented" => true}),
    do: "query_specs: find undocumented"

  defp tool_action_summary("query_specs", args),
    do: "query_specs list: #{inspect(args)}"

  defp tool_action_summary("specs_propose", %{"app" => app, "path" => path}),
    do: "specs_propose: #{app}/#{path}"

  defp tool_action_summary("specs_approve", %{"app" => app, "path" => path}),
    do: "specs_approve: #{app}/#{path}"

  defp tool_action_summary("specs_reject", %{"app" => app, "path" => path}),
    do: "specs_reject: #{app}/#{path}"

  defp tool_action_summary(_name, _args), do: "called"
end
