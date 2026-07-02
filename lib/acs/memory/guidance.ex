defmodule Acs.Memory.Guidance do
  @moduledoc """
  Generates guidance packets for agents when they claim tasks.

  Guidance packets are context-appropriate memory snippets injected
  into an agent's context at task claim time. They help agents
  follow established practices without having to search manually.

  ## Token Budget (per guidance packet category)
  - critical_axioms: max 5 entries
  - warnings: max 3 entries
  - relevant_patterns: max 5 entries
  - compressed_knowledge: max 500 tokens (approximate)

  ## Delivery Tiers
  - `:claim` — Compact packet delivered at task claim time
    Includes: axioms, warnings, maintenance, tool_reference, document_*, workflow_basics
  - `:full` — Complete packet delivered on explicit request
    Includes: all of :claim + patterns, knowledge, file_locking_protocol,
    memory_protocol, error_response_protocol, sleep_wake_protocol, agent_identity
  """

  @critical_axioms_max 5
  @warnings_max 3
  @patterns_max 5
  @knowledge_max_chars 2000

  @maintenance_instructions """
  If you find any of the above items are incorrect or outdated while working:
  1. Mark old items as stale: use set_memory_status(memory_id: "...", status: "stale", notes: "reason")
  2. Save a corrected version: use save_memory(kind: "...", title: "...", content: "...", scope_path: "...")
  3. For outdated cognition specs: use document_propose(app, path, updated_attrs) with corrected invariants
  """

  @tool_reference """
  ## Tool Reference - Use these when stuck

  ### How Tool Discovery Works
  Tools are organized in 3 progressive levels for organizational clarity. The MCP `tools/list`
  endpoint (what OpenCode calls on startup) returns **ALL tools at every level** — no level
  filtering is applied at the MCP listing layer. Every registered tool is always visible and
  callable by name.

  - **Level 1**: Core workflow tools — `claim_work`, `release_work`,
    `create_work`, `lock_file`, `unlock_file`, `get_present_status`, `get_locked_files`,
    `list_tasks`, `sleep`, `wake`, `submit_task_feedback`, `help`, `save_memory`,
    `list_memories`, `search_memories`, `generate_guidance_packet`, `document_get`,
    `document_search`, `document_list`, `document_list_undocumented`, and all `ant_*` tools
  - **Level 2**: `get_logs`, `list_categories`, `list_tools`,
    `refresh_tools`, `list_orgs`, `set_memory_status`, `document_propose`, `document_approve`,
    `document_reject`, plus Ant Dev tools like `get_system_reply`, `trigger_workflow`, etc.
  - **Level 3**: `list_error_traces`, `ack_error_trace`,
    `resolve_error_trace`, `create_task_from_error_trace`, `time`, `trigger_extraction_worker`,
    `get_message`

  ### How to Discover and Organize Tools

  - All tools are **always available and callable by name** — levels are purely organizational,
    not access control. If you know a tool name, call it directly.
  - **`help`** — Lists ALL available tools with their levels, categories, and parameters from all
    levels. Always start here when unsure.
  - **`list_tools(level: N)`** — Lists tools at level N and below. Example: `list_tools(level: 3)`
    shows every tool available.
  - **`list_tools(category: "category_name")`** — Lists ALL tools in a specific category at every
    level. Use this to find tools for your work area.
  - **Progressive disclosure is guidance-only**: Levels help you discover tools incrementally,
    but they do not restrict what you can call. Use `list_tools(level: 2)` to see Level 2 tools,
    or `list_tools(level: 3)` to see everything.

  ### Getting Unstuck
  - **get_logs(level: "error", limit: 50)** — Get recent error logs. First stop when something fails.
  - All tools can be invoked directly by name. If you know a tool exists (e.g., from `help`),
    call it — it will execute.
  """

  @document_instructions """
  ## Cognition Spec System

  Cognition specs document WHY modules exist, what invariants must hold, how they work, and what can go wrong.

  ### When to Propose a Spec

  - **After completing implementation of any new module**: Always propose a cognition spec using `document_propose(app, path, attrs)` unless one already exists
  - **When modules change**: Update the corresponding spec to reflect new behavior
  - **Before approving a spec**: Review invariants, workflows, failure_modes carefully

  ### Spec Quality Checklist

  Before proposing a spec, ensure it meets these minimum requirements:

  - [ ] **purpose**: Clear explanation of WHY this module exists (1-2 sentences)
  - [ ] **invariants**: List 2-3 truths that must ALWAYS hold about this module
  - [ ] **workflows**: Document the expected execution sequences (normal path)
  - [ ] **failure_modes**: Document at least 2 known failure scenarios
  - [ ] **constraints**: Document what this module does NOT do (non-goals, limitations)
  - [ ] **tags**: Add categorization tags to make specs searchable

  ### Available Tools

  | Tool | Level | Behavior |
  |------|-------|----------|
  | `document_get` | 1 | Get full spec by app + path |
  | `document_search` | 1 | Full-text search across specs |
  | `document_list` | 1 | List all specs, optionally filtered |
  | `document_list_undocumented` | 1 | Find modules without specs |
  | `document_propose` | 2 | Create/update spec (status="proposed") |
  | `document_approve` | 2 | Set status="approved" |
  | `document_reject` | 2 | Set status="under_review" |

  > Note: Level 2+ tools require explicit access. Call directly by name to use them.
  """

  @document_mismatch_protocol """
  ## Code vs. Spec Mismatch Protocol

  When working on a module that has an existing cognition spec, you may discover the code behavior differs from what the spec documents.

  **When this happens:**

  1. **PAUSE** — Do not proceed with your original implementation plan
  2. **IDENTIFY** — Document specifically what differs:
     - What does the spec say should happen?
     - What does the code actually do?
     - Which one needs to change?
  3. **ASK THE USER** — Present the mismatch:
     ```
     COGNITION MISMATCH: [module_name]
     
     Spec says: [what spec documents]
     Code does: [what code actually does]
     
     Options:
     A) Update code to match spec — implement [X] instead
     B) Update spec to match code — change spec to reflect [Y]
     C) Update both — spec describes [Z], code will be changed to [Z]
     ```
  4. **WAIT** — Do not proceed until the user decides
  5. **EXECUTE** — Update whichever source the user indicated

  **Important**: Never assume the spec is wrong or that the code is wrong. Ask the user.
  """

  @workflow_basics """
  ## Next Steps

  After claiming this task:

  1. **LOCK FILES** — `acs_lock_file(agent_id, task_id, file_path)` before each edit
  2. **DO THE WORK** — Write code, run tests, research
  3. **SAVE LEARNINGS** — `acs_save_memory(kind: "learning", ...)` before release
  4. **UNLOCK FILES** — `acs_unlock_file(agent_id, file_path: file_path)` when done editing
  5. **RELEASE** — `acs_release_work(agent_id, task_id)`
  6. **FEEDBACK** — `acs_submit_task_feedback(task_id, agent_id, learned_for_agents: "...")`

  If no tasks available: `acs_sleep(agent_id: "YourAgentName")`
  """

  @file_locking_protocol """
  ## Next Steps (after locking this file)

  - Edit the file
  - When done: `acs_unlock_file(agent_id, file_path: file_path)` or `acs_unlock_file(agent_id, task_id: task_id)`
  - 10-minute auto-release if you go silent
  - `acs_get_locked_files()` to see all locked files
  """

  @memory_protocol """
  ## Next Steps (during this task)

  - When you discover something useful: `acs_save_memory(kind: "learning", title: "...", content: "...", scope_path: "...")`
  - Memory kinds: observation, learning, warning, pattern, bug, decision, invariant, axiom
  - Save when: you found a pattern, encountered a pitfall, made a decision
  - Don't save: temporary state, obvious things, one-off events
  """

  @error_response_protocol """
  ## Next Steps (if you encounter errors)

  1. Try to resolve it
  2. If persistent:
     - `acs_list_error_traces()` — check if known
     - `acs_ack_error_trace(trace_id)` — mark as investigating
  3. Fix it
  4. `acs_resolve_error_trace(trace_id)` — mark as resolved

  Debugging: `get_logs(level: "error", limit: 50)` → `memory_health_check()` → `connection_diagnostic()`
  """

  @sleep_wake_protocol """
  ## Next Steps (when no tasks available)

  - `acs_sleep(agent_id: "MyAgent", timeout: 300)` — wait for tasks
  - You'll be woken when a task is dispatched to you
  - `acs_wake(agent_id: "MyAgent")` — cancel sleep manually
  - Release any active tasks before sleeping
  """

  @agent_identity """
  ## Agent Identity

  - Your agent_id persists across sessions
  - Multiple agents can work simultaneously
  - `acs_get_present_status()` to see who's working
  """

  @knowledge_workflow """
  ## Organizational Workflow

  This project uses structured workflows to maintain consistency:

  1. **Claim work** before editing files — ensures no conflicts
  2. **Lock files** before each edit — prevents simultaneous modifications
  3. **Save learnings** when you discover something useful — helps future agents
  4. **Unlock files** when done editing — frees the file for others
  5. **Release work** when task is complete — signals completion
  6. **Provide feedback** to help future agents — improves the system

  Follow these patterns to maintain consistency with the team.
  """

  @knowledge_file_locking """
  ## File Locking

  - Only one agent should edit a file at a time
  - Check for conflicts before starting
  - Release locks when done (10-minute auto-release if silent)
  - Use: get_locked_files() to check current locks
  """

  @knowledge_memory """
  ## Knowledge Memory

  Save learnings when you discover:
  - Patterns that others should follow
  - Pitfalls others should avoid
  - Decisions that should be documented

  Memory kinds: observation, learning, warning, pattern, bug, decision, invariant, axiom

  Use: save_memory() to persist knowledge
  """

  @knowledge_error """
  ## Error Handling

  When encountering errors:
  1. Check if it's a known error pattern — use list_error_traces()
  2. If persistent, escalate debugging — use get_logs() then connection_diagnostic()
  3. Document what you learned — use save_memory()
  """

  @knowledge_sleep """
  ## Task Availability

  When no tasks are available, wait for new assignments.
  Release any active tasks before switching focus.
  Use: sleep() to wait, wake() to cancel
  """

  @knowledge_identity """
  ## Agent Identity

  Multiple agents can work simultaneously.
  Each agent has a unique identifier that persists across sessions.
  Use: get_present_status() to see who's working
  """

  @doc """
  Generates a guidance packet for a given scope_path.

  ## Options
  - `tier`: `:full` (default) - includes all categories including patterns and knowledge
            `:claim` - only high-importance (>= 4) axioms and warnings, no patterns/knowledge
  - `mode`: `:mcp` (default) - includes MCP tool references for coding agents
            `:knowledge` - strips tool references, for Claude Chat/ChatGPT consumption

  Returns a map with:
  - :scope - the scope path
  - :tier - the tier used
  - :critical_axioms - list of high-importance axioms/invariants
  - :warnings - list of warnings for this scope
  - :relevant_patterns - list of relevant patterns/learnings
  - :compressed_knowledge - condensed knowledge string
  - :maintenance_instructions - instructions for flagging outdated items
  - :tool_reference - guidance on using help, list_tools, and get_logs
  - :document_instructions - cognition spec system instructions
  - :document_mismatch_protocol - how to handle code vs spec disagreements
  - :workflow_basics - standard agent workflow (claim tier and above)
  - :file_locking_protocol - file locking rules (full tier only)
  - :memory_protocol - knowledge memory protocol (full tier only)
  - :error_response_protocol - error handling (full tier only)
  - :sleep_wake_protocol - sleep/wake behavior (full tier only)
  - :agent_identity - agent identification (full tier only)
  """
  def generate(scope_path, opts \\ []) do
    tier = Keyword.get(opts, :tier, :full)
    mode = Keyword.get(opts, :mode, :mcp)
    allowed_teams = Keyword.get(opts, :allowed_teams)
    allowed_projects = Keyword.get(opts, :allowed_projects)

    search_opts = [{:scope_path, scope_path}, {:status, "approved"}]
    search_opts = if allowed_teams, do: search_opts ++ [allowed_teams: allowed_teams], else: search_opts
    search_opts = if allowed_projects, do: search_opts ++ [allowed_projects: allowed_projects], else: search_opts

    scope_memories =
      Acs.Memory.Search.list(search_opts)

    sorted = Enum.sort_by(scope_memories, & &1.importance, :desc)

    # Merge hardcoded tool guidance for known ACS tool scopes
    tool_guidance = Acs.Memory.ToolGuidance.for_scope(scope_path)

    case tier do
      :claim ->
        if mode == :knowledge do
          %{
            scope: scope_path,
            tier: :claim,
            mode: :knowledge,
            critical_axioms: merge_items(extract_axioms(sorted, min_importance: 4), tool_guidance, :critical_axioms, @critical_axioms_max),
            warnings: merge_items(extract_warnings(sorted, min_importance: 4), tool_guidance, :warnings, @warnings_max),
            relevant_patterns: [],
            compressed_knowledge: "",
            maintenance_instructions: @maintenance_instructions,
            tool_reference: "",
            document_instructions: @document_instructions,
            document_mismatch_protocol: @document_mismatch_protocol,
            workflow_basics: @knowledge_workflow,
            file_locking_protocol: @knowledge_file_locking,
            memory_protocol: @knowledge_memory,
            error_response_protocol: @knowledge_error,
            sleep_wake_protocol: @knowledge_sleep,
            agent_identity: @knowledge_identity
          }
        else
          %{
            scope: scope_path,
            tier: :claim,
            mode: :mcp,
            critical_axioms: merge_items(extract_axioms(sorted, min_importance: 4), tool_guidance, :critical_axioms, @critical_axioms_max),
            warnings: merge_items(extract_warnings(sorted, min_importance: 4), tool_guidance, :warnings, @warnings_max),
            relevant_patterns: [],
            compressed_knowledge: "",
            maintenance_instructions: @maintenance_instructions,
            tool_reference: @tool_reference,
            document_instructions: @document_instructions,
            document_mismatch_protocol: @document_mismatch_protocol,
            workflow_basics: @workflow_basics,
            file_locking_protocol: @file_locking_protocol,
            memory_protocol: @memory_protocol,
            error_response_protocol: @error_response_protocol,
            sleep_wake_protocol: @sleep_wake_protocol,
            agent_identity: @agent_identity
          }
        end

      :full ->
        if mode == :knowledge do
          %{
            scope: scope_path,
            tier: :full,
            mode: :knowledge,
            critical_axioms: merge_items(extract_axioms(sorted), tool_guidance, :critical_axioms, @critical_axioms_max),
            warnings: merge_items(extract_warnings(sorted), tool_guidance, :warnings, @warnings_max),
            relevant_patterns: merge_items(extract_patterns(sorted), tool_guidance, :relevant_patterns, @patterns_max),
            compressed_knowledge: merge_knowledge(compress_knowledge(sorted), tool_guidance),
            maintenance_instructions: @maintenance_instructions,
            tool_reference: "",
            document_instructions: @document_instructions,
            document_mismatch_protocol: @document_mismatch_protocol,
            workflow_basics: @knowledge_workflow,
            file_locking_protocol: @knowledge_file_locking,
            memory_protocol: @knowledge_memory,
            error_response_protocol: @knowledge_error,
            sleep_wake_protocol: @knowledge_sleep,
            agent_identity: @knowledge_identity
          }
        else
          %{
            scope: scope_path,
            tier: :full,
            mode: :mcp,
            critical_axioms: merge_items(extract_axioms(sorted), tool_guidance, :critical_axioms, @critical_axioms_max),
            warnings: merge_items(extract_warnings(sorted), tool_guidance, :warnings, @warnings_max),
            relevant_patterns: merge_items(extract_patterns(sorted), tool_guidance, :relevant_patterns, @patterns_max),
            compressed_knowledge: merge_knowledge(compress_knowledge(sorted), tool_guidance),
            maintenance_instructions: @maintenance_instructions,
            tool_reference: @tool_reference,
            document_instructions: @document_instructions,
            document_mismatch_protocol: @document_mismatch_protocol,
            workflow_basics: @workflow_basics,
            file_locking_protocol: @file_locking_protocol,
            memory_protocol: @memory_protocol,
            error_response_protocol: @error_response_protocol,
            sleep_wake_protocol: @sleep_wake_protocol,
            agent_identity: @agent_identity
          }
        end
    end
  end

  @doc """
  Generates a guidance packet for a specific task.
  Uses the task's scope path.

  ## Options
  - `tier`: `:full` (default) or `:claim`
  - `mode`: `:mcp` (default) or `:knowledge`
  """
  def for_task(task_id, opts \\ []) do
    tier = Keyword.get(opts, :tier, :full)
    mode = Keyword.get(opts, :mode, :mcp)

    task = Acs.Acs.get_task(task_id)

    case task do
      nil ->
        if mode == :knowledge do
          %{
            scope: nil,
            tier: tier,
            mode: :knowledge,
            critical_axioms: [],
            warnings: [],
            relevant_patterns: [],
            compressed_knowledge: "",
            maintenance_instructions: @maintenance_instructions,
            tool_reference: "",
            document_instructions: @document_instructions,
            document_mismatch_protocol: @document_mismatch_protocol,
            workflow_basics: @knowledge_workflow,
            file_locking_protocol: @knowledge_file_locking,
            memory_protocol: @knowledge_memory,
            error_response_protocol: @knowledge_error,
            sleep_wake_protocol: @knowledge_sleep,
            agent_identity: @knowledge_identity,
            scope_category: nil
          }
        else
          %{
            scope: nil,
            tier: tier,
            mode: :mcp,
            critical_axioms: [],
            warnings: [],
            relevant_patterns: [],
            compressed_knowledge: "",
            maintenance_instructions: @maintenance_instructions,
            tool_reference: @tool_reference,
            document_instructions: @document_instructions,
            document_mismatch_protocol: @document_mismatch_protocol,
            workflow_basics: @workflow_basics,
            file_locking_protocol: @file_locking_protocol,
            memory_protocol: @memory_protocol,
            error_response_protocol: @error_response_protocol,
            sleep_wake_protocol: @sleep_wake_protocol,
            agent_identity: @agent_identity,
            scope_category: nil
          }
        end

      task when is_map(task) ->
        task_map = if is_struct(task), do: Map.from_struct(task), else: task

        scope_path =
          (task_map[:file_paths] || [])
          |> List.first()
          |> scope_from_path()

        guidance = generate(scope_path, tier: tier, mode: mode)
        Map.put(guidance, :scope_category, scope_path)
    end
  end

  defp extract_axioms(memories, opts \\ []) do
    min_importance = Keyword.get(opts, :min_importance, 1)

    memories
    |> Enum.filter(fn m -> m.kind in ["axiom", "invariant", "decision"] end)
    |> Enum.filter(fn m -> m.importance >= min_importance end)
    |> Enum.take(@critical_axioms_max)
    |> Enum.map(fn m ->
      %{id: m.id, title: m.title, summary: m.summary, importance: m.importance}
    end)
  end

  defp extract_warnings(memories, opts \\ []) do
    min_importance = Keyword.get(opts, :min_importance, 1)

    memories
    |> Enum.filter(fn m -> m.kind == "warning" end)
    |> Enum.filter(fn m -> m.importance >= min_importance end)
    |> Enum.take(@warnings_max)
    |> Enum.map(fn m ->
      %{id: m.id, title: m.title, summary: m.summary, importance: m.importance}
    end)
  end

  defp extract_patterns(memories) do
    memories
    |> Enum.filter(fn m -> m.kind in ["pattern", "learning", "observation"] end)
    |> Enum.take(@patterns_max)
    |> Enum.map(fn m ->
      %{id: m.id, title: m.title, summary: m.summary, importance: m.importance}
    end)
  end

  defp compress_knowledge(memories) do
    memories
    |> Enum.map(fn m -> "#{m.title}: #{m.summary}" end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> String.slice(0, @knowledge_max_chars)
  end

  defp scope_from_path(nil), do: ""

  defp scope_from_path(path) when is_binary(path) do
    # Strip project root so scope_path is always relative
    project_root =
      Application.app_dir(:steward_acs) |> Path.dirname() |> Path.dirname()

    relative_path =
      if String.starts_with?(path, project_root) do
        String.replace_prefix(path, project_root <> "/", "")
      else
        path
      end

    relative_path
    |> String.split("/")
    |> Enum.slice(0..-2//1)
    |> Enum.join("/")
  end

  defp scope_from_path(_), do: ""

  # Merges hardcoded tool guidance items with memory-based items
  # Priority: 1) memory items (highest importance first), 2) hardcoded items fill remaining slots
  defp merge_items(memory_items, nil, _key, _max), do: memory_items

  defp merge_items(memory_items, tool_guidance, key, max) do
    hardcoded_items = Map.get(tool_guidance, key, [])
    merged = memory_items ++ hardcoded_items
    Enum.take(merged, max)
  end

  # Merges compressed knowledge with hardcoded knowledge
  defp merge_knowledge(memory_knowledge, nil), do: memory_knowledge

  defp merge_knowledge("", tool_guidance) do
    Map.get(tool_guidance, :compressed_knowledge, "")
  end

  defp merge_knowledge(memory_knowledge, tool_guidance) do
    hardcoded = Map.get(tool_guidance, :compressed_knowledge, "")
    merged = memory_knowledge <> "\n\n" <> hardcoded
    String.slice(merged, 0, @knowledge_max_chars)
  end
end
