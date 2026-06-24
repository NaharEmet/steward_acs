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
  """

  @critical_axioms_max 5
  @warnings_max 3
  @patterns_max 5
  @knowledge_max_chars 2000

  @maintenance_instructions """
  If you find any of the above items are incorrect or outdated while working:
  1. Mark old items as stale: use set_memory_status(memory_id: "...", status: "stale", notes: "reason")
  2. Save a corrected version: use save_memory(kind: "...", title: "...", content: "...", scope_path: "...")
  3. For outdated cognition specs: use cognition_propose(app, path, updated_attrs) with corrected invariants
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
    `list_memories`, `search_memories`, `generate_guidance_packet`, `cognition_get`,
    `cognition_search`, `cognition_list`, `cognition_list_undocumented`, and all `ant_*` tools
  - **Level 2**: `get_logs`, `list_categories`, `list_tools`,
    `refresh_tools`, `list_orgs`, `set_memory_status`, `cognition_propose`, `cognition_approve`,
    `cognition_reject`, plus Ant Dev tools like `get_system_reply`, `trigger_workflow`, etc.
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

  @cognition_instructions """
  ## Cognition Spec System

  Cognition specs document WHY modules exist, what invariants must hold, how they work, and what can go wrong.

  ### When to Propose a Spec

  - **After completing implementation of any new module**: Always propose a cognition spec using `cognition_propose(app, path, attrs)` unless one already exists
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
  | `cognition_get` | 1 | Get full spec by app + path |
  | `cognition_search` | 1 | Full-text search across specs |
  | `cognition_list` | 1 | List all specs, optionally filtered |
  | `cognition_list_undocumented` | 1 | Find modules without specs |
  | `cognition_propose` | 2 | Create/update spec (status="proposed") |
  | `cognition_approve` | 2 | Set status="approved" |
  | `cognition_reject` | 2 | Set status="under_review" |

  > Note: Level 2+ tools require explicit access. Call directly by name to use them.
  """

  @cognition_mismatch_protocol """
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
     ⚠️ COGNITION MISMATCH: [module_name]
     
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

  @doc """
  Generates a guidance packet for a given scope_path.

  ## Options
  - `tier`: `:full` (default) - includes all categories including patterns and knowledge
            `:claim` - only high-importance (>= 4) axioms and warnings, no patterns/knowledge

  Returns a map with:
  - :scope - the scope path
  - :tier - the tier used
  - :critical_axioms - list of high-importance axioms/invariants
  - :warnings - list of warnings for this scope
  - :relevant_patterns - list of relevant patterns/learnings
  - :compressed_knowledge - condensed knowledge string
  - :maintenance_instructions - instructions for flagging outdated items
  - :tool_reference - guidance on using help, list_tools, and get_logs
  """
  def generate(scope_path, opts \\ []) do
    tier = Keyword.get(opts, :tier, :full)

    scope_memories =
      Acs.Memory.Search.list(
        scope_path: scope_path,
        status: "approved"
      )

    sorted = Enum.sort_by(scope_memories, & &1.importance, :desc)

    # Merge hardcoded tool guidance for known ACS tool scopes
    tool_guidance = Acs.Memory.ToolGuidance.for_scope(scope_path)

    case tier do
      :claim ->
        %{
          scope: scope_path,
          tier: :claim,
          critical_axioms: merge_items(extract_axioms(sorted, min_importance: 4), tool_guidance, :critical_axioms, @critical_axioms_max),
          warnings: merge_items(extract_warnings(sorted, min_importance: 4), tool_guidance, :warnings, @warnings_max),
          relevant_patterns: [],
          compressed_knowledge: "",
          maintenance_instructions: @maintenance_instructions,
          tool_reference: @tool_reference,
          cognition_instructions: @cognition_instructions,
          cognition_mismatch_protocol: @cognition_mismatch_protocol
        }

      :full ->
        %{
          scope: scope_path,
          tier: :full,
          critical_axioms: merge_items(extract_axioms(sorted), tool_guidance, :critical_axioms, @critical_axioms_max),
          warnings: merge_items(extract_warnings(sorted), tool_guidance, :warnings, @warnings_max),
          relevant_patterns: merge_items(extract_patterns(sorted), tool_guidance, :relevant_patterns, @patterns_max),
          compressed_knowledge: merge_knowledge(compress_knowledge(sorted), tool_guidance),
          maintenance_instructions: @maintenance_instructions,
          tool_reference: @tool_reference,
          cognition_instructions: @cognition_instructions,
          cognition_mismatch_protocol: @cognition_mismatch_protocol
        }
    end
  end

  @doc """
  Generates a guidance packet for a specific task.
  Uses the task's scope path.

  ## Options
  - `tier`: `:full` (default) or `:claim`
  """
  def for_task(task_id, opts \\ []) do
    tier = Keyword.get(opts, :tier, :full)

    task = Acs.Acs.get_task(task_id)

    case task do
      nil ->
        %{
          scope: nil,
          tier: tier,
          critical_axioms: [],
          warnings: [],
          relevant_patterns: [],
          compressed_knowledge: "",
          maintenance_instructions: @maintenance_instructions,
          tool_reference: @tool_reference,
          cognition_instructions: @cognition_instructions,
          cognition_mismatch_protocol: @cognition_mismatch_protocol,
          scope_category: nil
        }

      task when is_map(task) ->
        task_map = if is_struct(task), do: Map.from_struct(task), else: task

        scope_path =
          (task_map[:file_paths] || [])
          |> List.first()
          |> scope_from_path()

        guidance = generate(scope_path, tier: tier)
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
