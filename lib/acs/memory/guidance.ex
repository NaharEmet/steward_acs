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
    Includes: axioms, warnings, maintenance, tool_reference, specs_*, workflow_basics
  - `:full` — Complete packet delivered on explicit request
    Includes: all of :claim + patterns, knowledge, file_locking_protocol,
    memory_protocol, error_response_protocol, sleep_wake_protocol, agent_identity
  """

  @critical_axioms_max 5
  @warnings_max 3
  @patterns_max 5
  @knowledge_max_chars 2000

  @maintenance_instructions """
Outdated items? 1) `set_memory_status(id, "stale", notes)` 2) `save_memory(kind, title, content, scope_path)` for corrected version 3) `specs_propose` for outdated specs
"""

  @tool_reference """
All tools callable by name. `help(category, level)` for filtered listing. `get_logs(level: "error")` first when stuck. Tools are organized by category (acs_core, knowledge, specs, error, diagnostic, skills).
"""

  @specs_instructions """
`specs_propose(app, path, purpose, invariants, workflows, failure_modes, constraints, tags)` after implementing a module. `query_specs(undocumented: true)` to find gaps. `specs_get(app, path)` to read.
"""

  @specs_instructions_short """
After completing work, `specs_propose(app, path, attrs)` if no spec exists. `query_specs(undocumented: true)` to find gaps.
"""

  @specs_mismatch_protocol """
Code differs from spec? 1) Pause. 2) Identify what differs (spec says X, code does Y). 3) Ask user which to update. 4) Execute decision. Never assume one is wrong.
"""

  @workflow_basics """
Start: create or claim a task in ACS before work. After claiming: 1) `lock_file`  2) do work  3) `save_memory`  4) `unlock_file`  5) `release_work`  6) `submit_task_feedback`
Finish: always `release_work` + `submit_task_feedback` before declaring done. Never skip these.
Every response includes `_next` with suggested next tools. No tasks? `sleep`
"""

  @file_locking_protocol """
`lock_file` before edit, `unlock_file` when done (by path or task_id). 10-min auto-release. `get_locked_files()` to check.
"""

  @memory_protocol """
`save_memory(kind, title, content, scope_path)` — eternal truths only (patterns, decisions, invariants). Kinds: observation, learning, warning, pattern, bug, decision, invariant, axiom. Not one-off events.
"""

  @error_response_protocol """
1) `list_error_traces()`  2) `ack_error_trace(id)` — investigating  3) fix → `resolve_error_trace(id)`  4) debug: `get_logs(level:"error")` → `connection_diagnostic()`
"""

  @sleep_wake_protocol """
`sleep(agent_id, timeout)` — blocks until task dispatched. `wake(agent_id)` to cancel. Release active tasks first.
"""

  @agent_identity """
Find your agent_id: `get_present_status(agent_id: "")` auto-registers and returns `assigned_agent_id`. Then use that name in all tool calls. The assigned name persists across sessions.
"""

  @knowledge_workflow """
Start: claim a task before work. After claiming: lock files → do work → save learnings → unlock files → release → submit feedback. Finish: always release + submit feedback before declaring done.
No tasks? `sleep`.
"""

  @knowledge_file_locking """
`lock_file` before editing. `unlock_file` when done. 10-min auto-release if silent. `get_locked_files()` to check.
"""

  @knowledge_memory """
`save_memory(kind, title, content, scope_path)` for patterns, pitfalls, decisions. Kinds: observation, learning, warning, pattern, bug, decision, invariant, axiom.
"""

  @knowledge_error """
1) `list_error_traces()` — check known  2) `get_logs()` → `connection_diagnostic()` to debug  3) `save_memory()` to document what you learned
"""

  @knowledge_sleep """
No tasks? `sleep()` blocks until dispatched. Release active tasks first. `wake()` to cancel.
"""

  @knowledge_identity """
Find your agent_id: `get_present_status(agent_id: "")` returns your assigned name. Use it in all tool calls — it persists across sessions.
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
  - :specs_instructions - specs system instructions
  - :specs_mismatch_protocol - how to handle code vs spec disagreements
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
    agent_role = Keyword.get(opts, :agent_role)

    search_opts = [{:scope_path, scope_path}, {:status, "approved"}, {:org, Acs.Org.current()}]

    search_opts =
      if allowed_teams, do: search_opts ++ [allowed_teams: allowed_teams], else: search_opts

    search_opts =
      if allowed_projects,
        do: search_opts ++ [allowed_projects: allowed_projects],
        else: search_opts

    search_opts = if agent_role, do: search_opts ++ [agent_role: agent_role], else: search_opts

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
            scope_category: scope_path,
            tier: :claim,
            mode: :knowledge,
            critical_axioms:
              merge_items(
                extract_axioms(sorted, min_importance: 4),
                tool_guidance,
                :critical_axioms,
                @critical_axioms_max
              ),
            warnings:
              merge_items(
                extract_warnings(sorted, min_importance: 4),
                tool_guidance,
                :warnings,
                @warnings_max
              ),
            relevant_patterns: [],
            compressed_knowledge: "",
            maintenance_instructions: @maintenance_instructions,
            tool_reference: "",
            specs_instructions: @specs_instructions_short,
            specs_mismatch_protocol: "",
            workflow_basics: @knowledge_workflow,
            file_locking_protocol: @knowledge_file_locking,
            memory_protocol: @knowledge_memory,
            error_response_protocol: @knowledge_error,
            sleep_wake_protocol: "",
            agent_identity: @knowledge_identity
          }
        else
          %{
            scope: scope_path,
            scope_category: scope_path,
            tier: :claim,
            mode: :mcp,
            critical_axioms:
              merge_items(
                extract_axioms(sorted, min_importance: 4),
                tool_guidance,
                :critical_axioms,
                @critical_axioms_max
              ),
            warnings:
              merge_items(
                extract_warnings(sorted, min_importance: 4),
                tool_guidance,
                :warnings,
                @warnings_max
              ),
            relevant_patterns: [],
            compressed_knowledge: "",
            maintenance_instructions: @maintenance_instructions,
            tool_reference: "",
            specs_instructions: @specs_instructions_short,
            specs_mismatch_protocol: "",
            workflow_basics: @workflow_basics,
            file_locking_protocol: @file_locking_protocol,
            memory_protocol: @memory_protocol,
            error_response_protocol: @error_response_protocol,
            sleep_wake_protocol: "",
            agent_identity: @agent_identity
          }
        end

      :full ->
        if mode == :knowledge do
          %{
            scope: scope_path,
            scope_category: scope_path,
            tier: :full,
            mode: :knowledge,
            critical_axioms:
              merge_items(
                extract_axioms(sorted),
                tool_guidance,
                :critical_axioms,
                @critical_axioms_max
              ),
            warnings:
              merge_items(extract_warnings(sorted), tool_guidance, :warnings, @warnings_max),
            relevant_patterns:
              merge_items(
                extract_patterns(sorted),
                tool_guidance,
                :relevant_patterns,
                @patterns_max
              ),
            compressed_knowledge: merge_knowledge(compress_knowledge(sorted), tool_guidance),
            maintenance_instructions: @maintenance_instructions,
            tool_reference: "",
            specs_instructions: @specs_instructions,
            specs_mismatch_protocol: @specs_mismatch_protocol,
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
            scope_category: scope_path,
            tier: :full,
            mode: :mcp,
            critical_axioms:
              merge_items(
                extract_axioms(sorted),
                tool_guidance,
                :critical_axioms,
                @critical_axioms_max
              ),
            warnings:
              merge_items(extract_warnings(sorted), tool_guidance, :warnings, @warnings_max),
            relevant_patterns:
              merge_items(
                extract_patterns(sorted),
                tool_guidance,
                :relevant_patterns,
                @patterns_max
              ),
            compressed_knowledge: merge_knowledge(compress_knowledge(sorted), tool_guidance),
            maintenance_instructions: @maintenance_instructions,
            tool_reference: @tool_reference,
            specs_instructions: @specs_instructions,
            specs_mismatch_protocol: @specs_mismatch_protocol,
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
    allowed_teams = Keyword.get(opts, :allowed_teams)
    allowed_projects = Keyword.get(opts, :allowed_projects)
    agent_role = Keyword.get(opts, :agent_role)

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
            specs_instructions: @specs_instructions_short,
            specs_mismatch_protocol: "",
            workflow_basics: @knowledge_workflow,
            file_locking_protocol: @knowledge_file_locking,
            memory_protocol: @knowledge_memory,
            error_response_protocol: @knowledge_error,
            sleep_wake_protocol: "",
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
            tool_reference: "",
            specs_instructions: @specs_instructions_short,
            specs_mismatch_protocol: "",
            workflow_basics: @workflow_basics,
            file_locking_protocol: @file_locking_protocol,
            memory_protocol: @memory_protocol,
            error_response_protocol: @error_response_protocol,
            sleep_wake_protocol: "",
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

        abac_opts =
          []
          |> then(fn o -> if allowed_teams, do: o ++ [allowed_teams: allowed_teams], else: o end)
          |> then(fn o ->
            if allowed_projects, do: o ++ [allowed_projects: allowed_projects], else: o
          end)
          |> then(fn o -> if agent_role, do: o ++ [agent_role: agent_role], else: o end)

        guidance = generate(scope_path, Keyword.merge([tier: tier, mode: mode], abac_opts))

        title = (task_map[:title] || "") |> String.downcase()
        task_context = build_task_context(title)

        guidance
        |> Map.put(:task_context, task_context)
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
    axioms = memories |> Enum.filter(fn m -> m.kind in ["axiom", "invariant", "decision"] end)
    warnings = memories |> Enum.filter(fn m -> m.kind == "warning" end)
    patterns = memories |> Enum.filter(fn m -> m.kind in ["pattern", "learning", "observation"] end)

    [maybe_section("Axioms", axioms), maybe_section("Warnings", warnings),
     maybe_section("Patterns & Learnings", patterns)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
    |> String.slice(0, @knowledge_max_chars)
  end

  defp maybe_section(_title, []), do: nil

  defp maybe_section(title, items) do
    body =
      items
      |> Enum.map(fn m -> "**#{m.title}**: #{m.summary}" end)
      |> Enum.join("\n")

    "## #{title}\n\n#{body}"
  end

  defp build_task_context(title) do
    cond do
      title =~ ~r/marketing|campaign|promot|content|seo|social|blog|advert/i ->
        """
        ## Marketing Context

        This task involves marketing activities. Considerations:
        - Ensure analytics/UTM tracking is set up (see guides/analytics.md)
        - Verify conversion events are firing correctly
        - Coordinate publishing timing with content calendar
        - Test all links and calls-to-action before release
        """

      title =~ ~r/test|spec|coverage|testing|rspec|exunit|assert/i ->
        """
        ## Testing Context

        This task involves tests or specs. Before releasing, ensure:
        - New tests pass with `mix test`
        - Existing tests are not broken
        - Consider both unit and integration test coverage
        """

      title =~ ~r/bug|fix|error|crash|issue|fault|broken|fail/i ->
        """
        ## Bug Fix Context

        This task fixes a bug. Before releasing, ensure:
        - The root cause is identified and fixed (not just symptoms)
        - Add a regression test that would catch this if reintroduced
        - Check for the same pattern elsewhere in the codebase
        """

      title =~ ~r/deploy|release|ci|cd|publish|rollout|build/i ->
        """
        ## Deployment Context

        This task involves deployment. Before releasing, ensure:
        - All changes are committed and pushed
        - The build pipeline passes
        - Review guides/deployment.md for the deployment workflow
        """

      title =~ ~r/migrat|schema|database|db|sql|ecto/i ->
        """
        ## Database Context

        This task involves database changes. Before releasing, ensure:
        - Run `mix ecto.migrate` to apply new migrations
        - Verify rollback works: `mix ecto.rollback`
        - Consider data migration for existing records
        """

      title =~ ~r/secur|auth|permission|oauth|api.?key|encrypt/i ->
        """
        ## Security Context

        This task involves security-sensitive changes. Before releasing, ensure:
        - No secrets or keys are committed or logged
        - Follow guides/secrets.md for managing secrets
        - Authentication and authorization paths are tested
        """

      title =~ ~r/refactor|clean.?up|optimize|performance|technical.?debt|rewrite/i ->
        """
        ## Refactoring Context

        This task involves refactoring. Before releasing, ensure:
        - Existing behaviour is preserved — don't change the API contract
        - Tests still pass (refactoring should not break tests)
        - Consider incremental changes rather than a big rewrite
        """

      title =~ ~r/document|docs?|readme|comment|guide|wiki|changelog/i ->
        """
        ## Documentation Context

        This task involves documentation. Considerations:
        - Keep docs close to the code they describe
        - Update specs alongside documentation
        - Use clear, concise language — avoid jargon
        """

      title =~ ~r/feature|add|new|implement|support|integrat/i ->
        """
        ## Feature Context

        This task adds a new feature. Before releasing, ensure:
        - Write tests for the new functionality
        - Update or add specs for any new modules
        - Consider backward compatibility
        - Update any relevant documentation
        """

      title =~ ~r/api|endpoint|route|controller|graphql|rest/i ->
        """
        ## API Context

        This task involves API changes. Before releasing, ensure:
        - API changes are backward compatible or versioned
        - Request/response formats are documented
        - Error responses follow existing conventions
        """

      title =~ ~r/ui|ux|view|template|frontend|component|layout|style|css/i ->
        """
        ## UI/Frontend Context

        This task involves UI changes. Before releasing, ensure:
        - Works across target viewport sizes (responsive)
        - Follows existing design patterns and conventions
        - Check for accessibility basics (keyboard nav, screen readers)
        """

      title =~ ~r/docker|container|k8s|kubernetes|compose|image/i ->
        """
        ## Container Context

        This task involves container/Docker changes. Before releasing, ensure:
        - Test the build locally with `docker compose build`
        - Keep image sizes small — prefer slim/alpine bases
        - Don't bake secrets into images
        """

      title =~ ~r/config|configure|setup|env|setting|option/i ->
        """
        ## Configuration Context

        This task involves configuration changes. Considerations:
        - Default values should be safe for local development
        - Document new config options in relevant guides
        - Use env vars for environment-specific values
        """

      true ->
        nil
    end
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
