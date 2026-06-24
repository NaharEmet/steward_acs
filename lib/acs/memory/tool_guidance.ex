defmodule Acs.Memory.ToolGuidance do
  @moduledoc """
  Hardcoded guidance for ACS tool categories.

  Provides fallback guidance when the memory store is empty or unavailable.
  Each tool category has pre-authored axioms, warnings, patterns, and knowledge
  that describe how to use those tools effectively.

  ## Scope Paths

  | Scope Path | Content |
  |---|---|
  | `agent_coordination_system/tools` | All tools overview |
  | `agent_coordination_system/tools/core` | Core ACS workflow tools |
  | `agent_coordination_system/tools/knowledge` | Memory/knowledge system tools |
  | `agent_coordination_system/tools/cognition` | Cognition spec tools |
  | `agent_coordination_system/tools/diagnostic` | Diagnostic/telemetry tools |
  | `agent_coordination_system/tools/crm` | CRM integration tools |

  Use `Acs.Memory.ToolGuidance.all_scopes_guidance/0` to retrieve the reference guide string.
  """

  @all_scopes_guidance """
  # ACS Tool Guidance

  The Agent Coordination System provides tools organized into 6 categories:
  acs_core (workflow), knowledge (memory), cognition (specs), diagnostic (telemetry), crm (integrations).

  Each category has hardcoded guidance for use when the memory store is empty or unavailable.
  Use `Acs.Memory.ToolGuidance.for_scope/1` to retrieve guidance for a specific scope path.
  Use `Acs.Memory.ToolGuidance.known_scopes/0` to list all available scope paths.
  """

  @scopes %{
    "agent_coordination_system/tools" => %{
      critical_axioms: [
        %{
          id: "toolguidance_all_axiom_1",
          title: "All tools callable by name regardless of level",
          summary:
            "All tools are always callable by name regardless of level. Levels are organizational, not access control.",
          importance: 5
        },
        %{
          id: "toolguidance_all_axiom_2",
          title: "Six tool categories",
          summary:
            "Tool categories group related tools: acs_core (workflow), knowledge (memory), cognition (specs), diagnostic (telemetry), crm (integrations).",
          importance: 4
        },
        %{
          id: "toolguidance_all_axiom_3",
          title: "Internal and external tools",
          summary:
            "The ACS tool system supports internal tools (compiled handlers) and external tools (HTTP endpoints via Bridge).",
          importance: 3
        },
        %{
          id: "toolguidance_all_axiom_4",
          title: "Discover tools via help and list_tools",
          summary:
            "Agents discover tools via help() for full reference or list_tools(category:) for filtered view.",
          importance: 4
        },
        %{
          id: "toolguidance_all_axiom_5",
          title: "Dynamic tool creation at runtime",
          summary:
            "New tools can be created at runtime using write_tool for endpoint-based tools without recompilation.",
          importance: 3
        }
      ],
      warnings: [
        %{
          id: "toolguidance_all_warning_1",
          title: "Do not hardcode tool names",
          summary:
            "Do not hardcode tool names in agent logic. Use help/list_tools for discovery to stay compatible across deployments.",
          importance: 4
        },
        %{
          id: "toolguidance_all_warning_2",
          title: "Dynamic tools are ephemeral",
          summary:
            "Dynamic tools created via write_tool are ephemeral — they persist only on the filesystem of the cluster node.",
          importance: 3
        }
      ],
      relevant_patterns: [
        %{
          id: "toolguidance_all_pattern_1",
          title: "Start with help then narrow with list_tools",
          summary:
            "Start with help() to see all available tools, then use list_tools(category:) to focus on specific areas.",
          importance: 4
        },
        %{
          id: "toolguidance_all_pattern_2",
          title: "Debug with get_logs first",
          summary:
            "When a tool errors, check get_logs(level: 'error') first for root cause analysis.",
          importance: 4
        }
      ],
      compressed_knowledge:
        "ACS tools: 6 categories. acs_core (Level 1-3): claim_work, release_work, create_work, lock_file, unlock_file, get_present_status, get_locked_files, list_tasks, sleep, wake, submit_task_feedback, help, get_logs, list_orgs, list_categories, list_tools, refresh_tools, list_error_traces, ack_error_trace, resolve_error_trace, create_task_from_error_trace, time. knowledge (Level 1-2): save_memory, list_memories, search_memories, set_memory_status, generate_guidance_packet. cognition (Level 1-2): cognition_get, cognition_search, cognition_list, cognition_list_undocumented, cognition_propose, cognition_approve, cognition_reject. diagnostic (Level 1): config_lookup, connection_diagnostic, find_similar_code, memory_health_check. crm (Level 1-2): crm_sync, crm_sync_object_type, crm_get_sync_state, crm_list_sources, crm_get_scheduler_status, crm_get_field_config, crm_trigger_scheduler. acs (Level 3): write_tool."
    },
    "agent_coordination_system/tools/core" => %{
      critical_axioms: [
        %{
          id: "toolguidance_core_axiom_1",
          title: "Claim before editing",
          summary:
            "Always claim_work before editing files — this prevents other agents from working on the same task.",
          importance: 5
        },
        %{
          id: "toolguidance_core_axiom_2",
          title: "Lock files before editing",
          summary:
            "Lock each file before editing with lock_file(task_id, file_path) to avoid merge conflicts.",
          importance: 5
        },
        %{
          id: "toolguidance_core_axiom_3",
          title: "Release work when done",
          summary:
            "Release work when done with release_work — this sends a feedback prompt to capture learnings.",
          importance: 5
        },
        %{
          id: "toolguidance_core_axiom_4",
          title: "Submit feedback after release",
          summary:
            "Submit_task_feedback after releasing to share learnings as knowledge memories for future agents.",
          importance: 4
        },
        %{
          id: "toolguidance_core_axiom_5",
          title: "Sleep/wake cycle for task dispatch",
          summary:
            "The sleep/wake cycle: agents call sleep() to block until a task arrives, then claim_work to claim it.",
          importance: 3
        }
      ],
      warnings: [
        %{
          id: "toolguidance_core_warning_1",
          title: "File locks auto-release after 10 minutes",
          summary:
            "File locks auto-release after 10 minutes. For long-running edits, re-lock files periodically.",
          importance: 4
        },
        %{
          id: "toolguidance_core_warning_2",
          title: "Cannot release another agent's task",
          summary:
            "Never release another agent's task — release_work validates ownership.",
          importance: 5
        },
        %{
          id: "toolguidance_core_warning_3",
          title: "Cannot sleep with active task",
          summary:
            "Calling sleep() with an active task will fail. Complete or release the current task first.",
          importance: 4
        }
      ],
      relevant_patterns: [
        %{
          id: "toolguidance_core_pattern_1",
          title: "Standard agent workflow",
          summary:
            "Standard agent workflow: create_work (or claim_work when tasked) → lock_file → edit → unlock_file → release_work → submit_task_feedback.",
          importance: 5
        },
        %{
          id: "toolguidance_core_pattern_2",
          title: "Create and claim in one call",
          summary:
            "Use create_work(agent_id, title, file_paths:) to create and claim in one operation.",
          importance: 4
        },
        %{
          id: "toolguidance_core_pattern_3",
          title: "Check agent activity before starting",
          summary:
            "Use get_present_status() to check what agents are doing before starting work to avoid conflicts.",
          importance: 4
        }
      ],
      compressed_knowledge:
        "Core ACS workflow: create_work/claim_work → lock_file → edit → unlock_file → release_work → submit_task_feedback. File locks: 10 min auto-release. Task states: available → claimed → in_progress → completed. Use get_present_status to check agent activity. Use list_tasks(agent_id:, status_filter:) to find work. Sleep() blocks until task dispatch."
    },
    "agent_coordination_system/tools/knowledge" => %{
      critical_axioms: [
        %{
          id: "toolguidance_knowledge_axiom_1",
          title: "Memories are eternal truths, not events",
          summary:
            "Memories are ETERNAL TRUTHS — reusable learnings, not events. Never save 'fixed bug X on date Y' — save the principle behind the fix.",
          importance: 5
        },
        %{
          id: "toolguidance_knowledge_axiom_2",
          title: "Use specific memory kinds",
          summary:
            "Valid memory kinds: observation, learning, warning, pattern, bug, decision, invariant, axiom. Choose the most specific kind.",
          importance: 4
        },
        %{
          id: "toolguidance_knowledge_axiom_3",
          title: "Memories start as proposed",
          summary:
            "Memories are proposed (status=proposed) by default. They must be approved before they appear in guidance packets.",
          importance: 4
        },
        %{
          id: "toolguidance_knowledge_axiom_4",
          title: "Get guidance before starting work",
          summary:
            "Use generate_guidance_packet(scope_path:) BEFORE starting work on a component to get context-specific guidance.",
          importance: 5
        },
        %{
          id: "toolguidance_knowledge_axiom_5",
          title: "Search before saving to avoid duplicates",
          summary:
            "Search memories before creating new ones to avoid duplicates — use search_memories(query:) with relevant keywords.",
          importance: 4
        }
      ],
      warnings: [
        %{
          id: "toolguidance_knowledge_warning_1",
          title: "Always set a meaningful scope_path",
          summary:
            "Scope_path is critical for organization. Always set a meaningful scope path when saving memories.",
          importance: 4
        },
        %{
          id: "toolguidance_knowledge_warning_2",
          title: "Vague memories pollute the store",
          summary:
            "Overly vague memories (no scope, no tags, low importance) rarely get approved and pollute the store.",
          importance: 3
        },
        %{
          id: "toolguidance_knowledge_warning_3",
          title: "Memory status changes are level 2",
          summary:
            "Setting memory status to 'approved' or 'deprecated' is a level 2 operation requiring explicit access.",
          importance: 3
        }
      ],
      relevant_patterns: [
        %{
          id: "toolguidance_knowledge_pattern_1",
          title: "Before implementing: get guidance and search memories",
          summary:
            "Before implementing: generate_guidance_packet for the scope → search_memories for relevant prior art → claim/create task.",
          importance: 5
        },
        %{
          id: "toolguidance_knowledge_pattern_2",
          title: "After implementing: save learnings and submit feedback",
          summary:
            "After implementing: save_memory with key learnings → submit_task_feedback with what you discovered.",
          importance: 4
        },
        %{
          id: "toolguidance_knowledge_pattern_3",
          title: "Browse existing knowledge with list_memories",
          summary:
            "Use list_memories(scope_path:) to browse what knowledge exists for a component.",
          importance: 3
        }
      ],
      compressed_knowledge:
        "Memory kinds: observation, learning, warning, pattern, bug, decision, invariant, axiom. Status flow: proposed → approved/rejected → stale/deprecated. Key tools: save_memory (create), list_memories (browse), search_memories (find), set_memory_status (approve/reject), generate_guidance_packet (get context). Always save eternal truths, not events."
    },
    "agent_coordination_system/tools/cognition" => %{
      critical_axioms: [
        %{
          id: "toolguidance_cognition_axiom_1",
          title: "Specs document WHY a module exists",
          summary:
            "Cognition specs document WHY a module exists — its purpose, invariants, workflows, failure modes, and constraints.",
          importance: 5
        },
        %{
          id: "toolguidance_cognition_axiom_2",
          title: "Every module should have a spec",
          summary:
            "Every module should have a spec. Use cognition_list_undocumented() to find modules missing specs.",
          importance: 4
        },
        %{
          id: "toolguidance_cognition_axiom_3",
          title: "Ask the user when code and spec disagree",
          summary:
            "When code and spec disagree: ASK THE USER. Never assume which one is wrong.",
          importance: 5
        },
        %{
          id: "toolguidance_cognition_axiom_4",
          title: "Specs have versions",
          summary:
            "Specs have versions. Approving a spec increments the version and recomputes the spec_hash.",
          importance: 3
        }
      ],
      warnings: [
        %{
          id: "toolguidance_cognition_warning_1",
          title: "Do not skip proposing specs for new modules",
          summary:
            "Do not skip proposing specs for new modules. Documentation debt accrues exponentially.",
          importance: 4
        },
        %{
          id: "toolguidance_cognition_warning_2",
          title: "Wrong invariants are worse than no spec",
          summary:
            "Proposing a spec with wrong invariants is worse than no spec — it misleads future agents.",
          importance: 4
        }
      ],
      relevant_patterns: [
        %{
          id: "toolguidance_cognition_pattern_1",
          title: "Check undocumented after implementing",
          summary:
            "After implementing a module: use cognition_list_undocumented() to check if it needs a spec → cognition_propose() to document it.",
          importance: 4
        },
        %{
          id: "toolguidance_cognition_pattern_2",
          title: "Standard spec quality checklist",
          summary:
            "Standard spec quality check: purpose (why), invariants (what must hold), workflows (how), failure_modes (what breaks), constraints (non-goals), tags (search).",
          importance: 4
        }
      ],
      compressed_knowledge:
        "Cognition tools: cognition_get (read spec), cognition_search (find specs), cognition_list (browse), cognition_list_undocumented (find gaps), cognition_propose (create), cognition_approve/reject (review). Every module needs a spec. When code ≠ spec, ask user."
    },
    "agent_coordination_system/tools/diagnostic" => %{
      critical_axioms: [
        %{
          id: "toolguidance_diagnostic_axiom_1",
          title: "config_lookup for opencode configuration",
          summary:
            "config_lookup() reads opencode configuration — agents, skills, plugins, MCP servers. Use before assuming what's available.",
          importance: 4
        },
        %{
          id: "toolguidance_diagnostic_axiom_2",
          title: "connection_diagnostic for service health",
          summary:
            "connection_diagnostic() checks reachability of ACS, database, and LLM providers. First step when something fails to connect.",
          importance: 5
        },
        %{
          id: "toolguidance_diagnostic_axiom_3",
          title: "find_similar_code for prior patterns",
          summary:
            "find_similar_code(query:) performs semantic search across approved memories. Use to find prior patterns before implementing.",
          importance: 3
        },
        %{
          id: "toolguidance_diagnostic_axiom_4",
          title: "memory_health_check for pipeline health",
          summary:
            "memory_health_check() monitors the Anantha memory pipeline health. Specify org_id for scoped checks.",
          importance: 3
        }
      ],
      warnings: [
        %{
          id: "toolguidance_diagnostic_warning_1",
          title: "Avoid verbose mode in production",
          summary:
            "connection_diagnostic() with verbose:true returns detailed error info — avoid in production Slack channels.",
          importance: 3
        }
      ],
      relevant_patterns: [
        %{
          id: "toolguidance_diagnostic_pattern_1",
          title: "New environment checkout sequence",
          summary:
            "Start a new environment checkout with connection_diagnostic() → config_lookup() to understand what's available.",
          importance: 4
        },
        %{
          id: "toolguidance_diagnostic_pattern_2",
          title: "Debugging escalation order",
          summary:
            "When debugging: get_logs(level:'error') → memory_health_check() → connection_diagnostic() in that order.",
          importance: 4
        }
      ],
      compressed_knowledge:
        "Diagnostic tools: config_lookup (opencode config), connection_diagnostic (service health), find_similar_code (semantic search), memory_health_check (pipeline health). Start new environments with connection_diagnostic() + config_lookup()."
    },
    "agent_coordination_system/tools/crm" => %{
      critical_axioms: [
        %{
          id: "toolguidance_crm_axiom_1",
          title: "CRM tools sync external data into Anantha",
          summary:
            "CRM tools allow syncing data from external CRM sources (HubSpot, Zoho, SafetyConnect) into Anantha.",
          importance: 4
        },
        %{
          id: "toolguidance_crm_axiom_2",
          title: "crm_sync triggers full sync",
          summary:
            "crm_sync triggers a full sync of all configured object types for a source.",
          importance: 4
        },
        %{
          id: "toolguidance_crm_axiom_3",
          title: "crm_list_sources shows configured sources",
          summary:
            "crm_list_sources shows all configured CRM sources and their status.",
          importance: 3
        },
        %{
          id: "toolguidance_crm_axiom_4",
          title: "crm_get_field_config shows field mappings",
          summary:
            "crm_get_field_config shows the field mapping between CRM fields and Anantha fields.",
          importance: 3
        }
      ],
      warnings: [
        %{
          id: "toolguidance_crm_warning_1",
          title: "Sync operations can be slow",
          summary:
            "CRM sync operations can be slow for large datasets. Check crm_get_sync_state to monitor progress.",
          importance: 4
        },
        %{
          id: "toolguidance_crm_warning_2",
          title: "Understand data model before modifying configs",
          summary:
            "Do not modify CRM field configs without understanding the data model — use crm_get_field_config first.",
          importance: 4
        }
      ],
      relevant_patterns: [
        %{
          id: "toolguidance_crm_pattern_1",
          title: "Inspect sources and field config before operations",
          summary:
            "Before CRM operations: crm_list_sources() → crm_get_field_config(source:) to understand the data mapping.",
          importance: 4
        },
        %{
          id: "toolguidance_crm_pattern_2",
          title: "Verify sync after configuring new source",
          summary:
            "After configuring a new source: crm_sync(source:) → crm_get_sync_state(source:) to verify.",
          importance: 4
        }
      ],
      compressed_knowledge:
        "CRM tools: crm_sync (full sync), crm_sync_object_type (single type), crm_get_sync_state (monitor progress), crm_list_sources (configured sources), crm_get_scheduler_status (scheduler state), crm_get_field_config (field mappings), crm_trigger_scheduler (manual trigger). Workflow: list sources → check field config → sync → monitor state."
    }
  }

  @doc """
  Returns the reference guide string describing all ACS tool guidance scopes.
  """
  def all_scopes_guidance do
    @all_scopes_guidance
  end

  @doc """
  Returns hardcoded tool guidance for a given scope path.
  Returns nil if no guidance exists for the scope.
  """
  def for_scope(scope_path) when is_binary(scope_path) do
    scope = String.trim(scope_path)
    Map.get(@scopes, scope)
  end

  @doc """
  Returns all known tool scope paths that have hardcoded guidance.
  """
  def known_scopes do
    Map.keys(@scopes)
  end
end
