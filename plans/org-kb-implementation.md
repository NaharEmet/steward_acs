# ACS as Org Knowledge Base — Implementation Plan (v3)

## Overview

Extend Steward ACS from a single-agent memory system into a multi-user org knowledge base
with Obsidian vault support, team-scoped visibility, natural language querying, and
role-based access — all while preserving existing infra (embeddings, search, auditor,
file watcher, MCP protocol).

### Key Constraint: DB Can Be Reset

The SQLite/Postgres index is **derived** from canonical YAML/Markdown files on disk.
Migrations are NOT needed: edit schemas + changesets, then reset the DB
(`mix ecto.reset`). Canonical files on disk are the only persistent state.

### v3 Updates (from final review)

This plan incorporates the v2 seven improvements **plus** twelve approved updates:

1. **Memory vs Document boundary** — explicit invariant; ≤5 paragraphs = memory, >5 =
   document; validation enforces it.
2. **Document editing presence signal** — `editing_by` + `last_edit_heartbeat`; awareness
   only, no locking.
3. **Document conflict handling** — Last Write Wins for MVP; `version`/`updated_by`/
   `updated_at` metadata captured for future optimistic concurrency.
4. **Conflict event memories** — document conflicts auto-generate a memory for
   auditability.
5. **Value auditing agent** — new agent detecting contradictions, superseded decisions,
   stale context, conflicting observations. Human approval required.
6. **Memory lifecycle rules** — permanent / semi-permanent / temporal retention policies.
7. **Frontmatter parser** — battle-tested library preferred; frontmatter valid only at
   file start; read opening delimiter, read first closing delimiter, body is remainder.
8. **File watcher debounce** — 1000ms (up from 500ms) for Obsidian/Syncthing/git/NAS.
9. **Content hashing** — `sha256` on indexed content to skip unchanged reindexing/embedding.
10. **Document model clarification** — Document + DocumentChunk architecture anticipated,
    chunk storage may be deferred.
11. **Document metadata** — `source` field (uploaded/obsidian/github/google_drive/notion/generated).
12. **Chunk-level permissions** — team/project/visibility copied onto chunks at index time.

Plus two final corrections:

- **ABAC query logic** — visibility-driven authorization (`visibility='org' OR (visibility='team' AND team IN ...) OR (visibility='project' AND project IN ...)`), not the looser `team IS NULL` variant.
- **`work_note` embedded** — `work_note` IS embedded (contains searchable knowledge); only `context`, `status`, `activity` skip embeddings.

And one structural change:

- **Separate folders** for memories and documents within the vault.

### v2 Improvements Retained

1. **Obsidian sync** — `OBSIDIAN_VAULT_PATH` env var; transport is ops concern.
2. **Temporal kinds bypass auditor + embeddings** — `@auditable_kinds` / `@embeddable_kinds` gate pipelines.
3. **`ask` tool structured params** — no server-side NL parsing.
4. **Keep `Acs.Cognition` module name** — add fields, rename only MCP tool names.
5. **ABAC in Ecto queries** — DB-level `WHERE`, not post-hoc filter.
6. **Single extension-aware Loader** — no store behaviour abstraction.
7. **File watcher incremental upsert** — changed file only, not full `sync_all/0`.

---

## Memory vs Document Boundary (Explicit Invariant)

This is a first-class design rule enforced at save time.

### Memory

```text
- Maximum 5 paragraphs
- Single idea
- Atomic knowledge unit
- Single embedding
- Created by humans/agents inside ACS
```

### Document

```text
- More than 5 paragraphs
- Multiple sections/topics
- Chunked for retrieval
- Multiple embeddings
- Usually imported from outside ACS
```

### Enforcement

`lib/acs/memory/memory.ex`:

```elixir
@max_memory_paragraphs 5

def validate(%__MODULE__{content: content} = m) do
  # ... existing validations ...
  paragraph_count = count_paragraphs(content)
  if paragraph_count > @max_memory_paragraphs do
    {:error, "Memory exceeds maximum size (#{@max_memory_paragraphs} paragraphs). " <>
             "Create a document instead."}
  else
    :ok
  end
end
```

`count_paragraphs/1` splits content on blank lines (≥2 newlines), filters empty blocks.

On attempted `save_memory` with exceeded size, the tool returns the rejection message —
the client AI is expected to call `document_create` instead. No automatic conversion.

### Separate Folders

Within the vault / memory dir:

```text
priv/acs_memory/
├── memories/              # atomic knowledge memories (.md or .yaml)
│   ├── engineering/
│   │   └── acs/
│   │       └── cache/
│   │           └── 2f5a3b.md
│   └── ...
├── documents/             # org documents (.md)
│   ├── policies/
│   │   └── auth_policy.md
│   ├── processes/
│   └── ...
└── .obsidian/             # excluded from watcher
```

- **Memories** keyed by `scope_path` under `memories/`.
- **Documents** keyed by `document_type` subdirectory under `documents/`.
- The existing `scope_path` field drives memories; documents use a `slug` or `id` filename.
- Loader's `memory_to_path/1` routes to `memories/`; Cognition Loader's path routes to
  `documents/`.

---

## Phase 1 — Extension-Aware Loader + Obsidian Format

**Goal:** The existing `Acs.Memory.Loader` reads and writes both `.yaml` and `.md` files.
Write format governed by `MEMORY_STORE`. Obsidian vault mounted via `OBSIDIAN_VAULT_PATH`.

### New File: `lib/acs/memory/frontmatter.ex`

A frontmatter parser. Per approved update #7: prefer a battle-tested library if available,
else implement carefully:

```
Frontmatter.split/1:
  1. Read file content
  2. Frontmatter is valid ONLY at file start (first non-whitespace chars are "---\n")
  3. Read opening "---\n" delimiter
  4. Read the FIRST closing "\n---\n" delimiter — everything after is body, even if "---" appears in markdown body (e.g. horizontal rules)
  5. YamlElixir.read_from_string on the frontmatter block (returns map)
  6. Return {:ok, frontmatter_map, body} | {:error, reason}
```

Design note: Obsidian's horizontal rule `---` in a markdown body is preceded by a blank
line, so the rule is: the closing delimiter must be the first `---` on its own line after
the opening delimiter, with no content already in the body. This avoids the accidental
parsing issue mentioned in update #7.

### Config

| Env Var | Values | Default | Purpose |
|---------|--------|---------|---------|
| `MEMORY_STORE` | `"yaml"` \| `"obsidian"` | `"yaml"` | Write format for new memories |
| `OBSIDIAN_VAULT_PATH` | filesystem path | unset | If set, `Loader.memory_dir/0` returns this path. Ops mounts the vault here (symlink/bind/Syncthing/git). |

### Changes to `lib/acs/memory/loader.ex`

| Function | Change |
|----------|--------|
| `memory_dir/0` | Runtime: `Application.get_env(:steward_acs, :obsidian_vault_path) \|\| Path.join(Application.app_dir(:steward_acs), "priv/acs_memory")` (no compile-time `@memory_dir` attr) |
| `list_files/1` | Glob `**/*.{yaml,yml,md}` — both extensions |
| `yaml_file?/1` → `memory_file?/1` | Accept `.yaml`, `.yml`, `.md`, `.MD` |
| `relevant_file?/1` | Exclude paths containing `/.obsidian/` (no existing dotfile filter) |
| `load_file/1` | Dispatch `.md` → `Frontmatter.split/1` then build Memory struct from frontmatter map + body; else existing `YamlElixir.read_from_file` |
| `save/1` | If `memory_store == "obsidian"` → write `.md` via `Frontmatter.serialize/2` (YAML frontmatter + markdown body); else existing YAML serializer |
| `memory_to_path/1` | Write to `memories/<scope_path>/<id>.<ext>`; extension determined by active `MEMORY_STORE` |

### Changes to `lib/acs/memory/file_watcher.ex`

| Concern | Change |
|---------|--------|
| File patterns | Accept `.md` events (currently `.yaml` only) |
| `.obsidian/` exclusion | Explicitly ignore any path containing `/.obsidian/` |
| **Debounce (update #8)** | Increase from 500ms to **1000ms** — Obsidian/Syncthing/git/NAS generate multiple events per save. Workflow: file event → reset timer → 1000ms silence → process. |
| **Incremental upsert (v2 #7)** | On debounced single-file event, call `Indexer.upsert_memory_file/1` (new) for the **changed file only**, NOT `sync_all/0`. Falls back to `sync_all/0` only for bulk events (directory rename, initial startup). |

### Markdown File Format (Memories)

```markdown
---
id: 2f5a3b
kind: observation
status: approved
title: Cache invalidation on cluster failover
tags: [cache, cluster]
scope_path: engineering/acs/cache
importance: 3
team: engineering
project: acs
visibility: team
sha256: 9f2c...
created_by: alice
created_at: 2026-06-30T10:00:00Z
updated_at: 2026-06-30T10:00:00Z
---

When a cluster node fails over, the ETS cache must be rebuilt from
the database. Stale entries persist across failover and cause
incorrect agent status reads.

## Details

The `Acs.Cache` process is supervised under `Acs.Application`.
```

### v3 Drops vs v2

- ❌ `lib/acs/memory/store/behaviour.ex`
- ❌ `lib/acs/memory/store/yaml_store.ex`
- ❌ `lib/acs/memory/store/obsidian_store.ex`
- ✅ Keep only `lib/acs/memory/frontmatter.ex`

---

## Phase 2 — New Memory Kinds + Pipeline Routing + Lifecycle (update #6)

**Goal:** Support temporal work-context memories with **kind-specific pipeline routing**
and **lifecycle retention policies**.

### Changes to `lib/acs/memory/memory.ex`

Add to `@kind_types`:
```elixir
@kind_types ~w(observation learning warning pattern bug decision invariant axiom
               context status work_note activity)
```

Default status for temporal kinds: `context`/`status`/`activity` start as `"approved"`.
`work_note` starts as `"proposed"` (still auditable — see below).

### Pipeline Routing (v2 #2 + v3 work_note correction)

**`lib/acs/memory/auditor.ex`:**
```elixir
@auditable_kinds ~w(observation learning warning pattern bug decision invariant axiom work_note)
# fetch_auditable_memories/0 adds WHERE kind IN (@auditable_kinds)
# context, status, activity are NEVER audited (auto-approved)
```

**`lib/acs/memory/embedding.ex`:**
```elixir
@embeddable_kinds ~w(observation learning warning pattern bug decision invariant axiom work_note)
# ensure_embeddings/0 and embed_single_memory/1 skip non-embeddable kinds
# context, status, activity have NO embeddings (ephemeral, don't pollute vector index)
# work_note IS embedded — contains searchable knowledge users later query semantically
```

| Kind | Audited | Embedded | Default Status | Retention |
|------|---------|----------|----------------|-----------|
| decision, invariant, warning, axiom | ✅ | ✅ | proposed | **permanent** — never auto-archived |
| observation, learning, pattern, bug | ✅ | ✅ | proposed | **semi-permanent** — candidate for review |
| work_note | ✅ | ✅ | proposed | **temporal** — configurable retention |
| context | ❌ | ❌ | approved | **temporal** — archive at project completion |
| status | ❌ | ❌ | approved | **temporal** — archive when replaced |
| activity | ❌ | ❌ | approved | **temporal** — archive after 30 days |

### Memory Lifecycle Rules (update #6)

New module `lib/acs/memory/lifecycle.ex`:

```elixir
defmodule Acs.Memory.Lifecycle do
  @permanent_kinds ~w(decision invariant warning axiom)
  @semi_permanent_kinds ~w(observation learning pattern bug)
  @temporal_kinds ~w(context status work_note activity)

  @temporal_retention %{
    "activity" => {:days, 30},
    "status" => {:when_replaced, nil},      # archive when newer status for same scope
    "context" => {:project_completion, nil}, # archive when project marked complete
    "work_note" => {:days, 90}              # configurable
  }

  def archivable?(memory)
  def archive_due?(memory, now)
  def retention_policy(kind)
end
```

Enforcement: a scheduled task (reuses Sweeper infrastructure pattern) checks temporal
memories periodically and transitions to `archived` status. **No automatic deletion** —
archived memories remain on disk and in the index (just excluded from default queries).

### Changes to `lib/acs/memory/schema.ex`

Add the 4 new kinds to `validate_inclusion(:kind, ...)` hardcoded list (schema.ex:44).

No DB migration — `kind` is a string column. Reset DB via `mix ecto.reset`.

---

## Phase 3 — Cognition Extends to Org Documents (update #10, #11, #12)

**Goal:** Repurpose the cognition spec system to hold org documentation. **Keep the
`Acs.Cognition` Elixir module name** (v2 #4) — add fields, rename only MCP tool names.
Anticipate a Document + DocumentChunk architecture (update #10) even if chunk storage
is deferred.

### Changes to `lib/acs/cognition/entry.ex`

Add fields to the existing `Acs.Cognition.Entry` struct:

```elixir
document_type: String.t() | nil,   # "policy" | "process" | "guideline" | "reference" | "spec"
content: String.t() | nil,         # markdown body (for document-type entries)
source: String.t() | nil,          # update #11: "uploaded" | "obsidian" | "github" | "google_drive" | "notion" | "generated"
sha256: String.t() | nil,          # update #9: content hash for dedup/change detection
version: integer(),                # update #3: for future optimistic concurrency (existing field)
updated_by: String.t() | nil,      # update #3
team: String.t() | nil,
project: String.t() | nil,
visibility: String.t()             # default "org"
```

Legacy spec fields (`purpose`, `invariants`, `workflows`, `failure_modes`,
`state_machine`, `constraints`, `input`, `output`, `expected_transformation`) remain for
backward compatibility — used when `document_type` is nil (legacy spec) or
`document_type: "spec"`.

### DocumentChunk Model Anticipation (update #10)

The architecture should anticipate chunked documents even if chunk storage is deferred.
Create the schema now; populate lazily:

`lib/acs/cognition/document_chunk.ex` (new):
```elixir
defmodule Acs.Cognition.DocumentChunk do
  use Ecto.Schema
  schema "acs_document_chunks" do
    field :document_id, :string       # FK to Entry.id
    field :chunk_index, :integer
    field :content, :string            # chunk text (≈500-1000 char overlap windows)
    field :embedding, :string         # JSON-serialized vector (reuse VectorIndex storage)
    field :team, :string              # update #12: copied from Document at indexing
    field :project, :string           # update #12
    field :visibility, :string        # update #12 — avoids joins during vector retrieval
    field :sha256, :string            # chunk-level hash
    timestamps()
  end
end
```

For MVP, chunks may remain empty and `document.content` is embedded whole. When chunking
is enabled (future flag), chunks are created during indexing with `team`/`project`/
`visibility` **copied** from the parent document (update #12) to avoid expensive joins
during vector retrieval.

### Changes to `lib/acs/cognition/loader.ex`

| Function | Change |
|----------|--------|
| `specs_path/0` | Resolve `OBSIDIAN_VAULT_PATH` if set → `<vault>/documents/`; else default path |
| `list_in_dir` | Glob `**/*.{yaml,yml,md}` (add `.md`) |
| `load_file/1` | Dispatch `.md` through `Frontmatter.split/1` (reuse from Phase 1) |
| `encode_yaml` | If `document_type` present and `memory_store == "obsidian"` → write `.md` with frontmatter + `content` body |

### MCP Tool Rename (Module Name Unchanged)

`lib/acs/cognition/tools.ex`:

| Old Tool Name | New Tool Name |
|---------------|---------------|
| `cognition_search` | `document_search` |
| `cognition_get` | `document_get` |
| `cognition_create` | `document_create` |
| `cognition_update` | `document_update` |
| `cognition_list` | `document_list` |
| `cognition_approve` | `document_approve` |
| `cognition_invalidate` | `document_invalidate` |

Add `document_type`, `content`, `source`, `team`, `project`, `visibility` to
`@allowed_fields`.

### Other File Changes

| File | Change |
|------|--------|
| `lib/acs/memory/tool_guidance.ex` | `cognition_*` → `document_*` tool name refs |
| `lib/acs/memory/guidance.ex` | `@cognition_instructions` → `@document_instructions`; tool name refs |

### Markdown File Format (Documents)

```markdown
---
id: auth_policy
document_type: policy
title: Authentication Policy
status: published
source: obsidian
version: 3
updated_by: bob
team: engineering
project: acs
visibility: org
sha256: 1a2b...
created_at: 2026-06-01T08:00:00Z
updated_at: 2026-06-30T14:00:00Z
---

## Overview
All access to ACS MCP tools requires an API key.

## Key Types
- Admin keys: full tool access
- Collaborator keys: `ask` tool only
...
```

### v3 Drops vs v2

- ❌ `git mv lib/acs/cognition/ → lib/acs/documents/` — no rename
- ❌ Global `Acs.Cognition.*` → `Acs.Documents.*` module alias churn
- ❌ Mix task `migrate_cognition_specs` (fields are additive/optional)
- ✅ Add `DocumentChunk` schema now (may stay empty for MVP)

---

## Phase 4 — ABAC: Visibility-Driven Authorization (v3 correction)

**Goal:** Scope memory and document visibility by team and project, enforced at the
**database query level** (v2 #5), using **visibility-driven authorization** (v3
correction — safer and easier to reason about).

### New Fields on Memory/Document

`lib/acs/memory/schema.ex` / `lib/acs/cognition/entry.ex`:
```elixir
field :team, :string
field :project, :string
field :visibility, :string, default: "org"   # "org" | "team" | "project"
```

### Visibility-Driven Query Logic (v3 correction)

Replace the v2 looser variant with explicit visibility-driven authorization:

```elixir
# Indexer.list_memories/2 and search/2 — pseudocode for the WHERE clause
where: fragment(
  "(visibility = 'org')
   OR (visibility = 'team' AND team IN (?))
   OR (visibility = 'project' AND project IN (?))",
  ^allowed_teams, ^allowed_projects
)
```

Rules:
- `visibility: "org"` → visible to everyone
- `visibility: "team"` AND `team` in `allowed_teams` → visible
- `visibility: "project"` AND `project` in `allowed_projects` → visible
- Everything else → hidden

This is stricter and easier to reason about than the v2 `team IS NULL` variant. There's
no implicit "null = org-wide" — `visibility: "org"` is the explicit default for org-wide
items.

### Developer Schema Extension

`lib/acs/developers/developer_api_key.ex`:
```elixir
field :allowed_teams, {:array, :string}
field :allowed_projects, {:array, :string}
validate_inclusion(:role, ~w(admin service reader collaborator))
```

### Threading Attributes Through the Stack

| File | Change |
|------|--------|
| `lib/acs/mcp/protocol.ex` | Inject `_auth_allowed_teams` + `_auth_allowed_projects` into tool args at `tools/call` |
| `lib/acs/mcp/plugs/mcp_auth.ex` | Pass `allowed_teams`/`allowed_projects` to `conn.assigns` |
| `lib/acs/mcp/plugs/strategies/developer.ex` | Read `allowed_teams`/`allowed_projects` from authenticated key |
| `lib/acs/mcp/tools/memory_handlers.ex` | Extract ABAC attrs from args, pass to Indexer; add optional `team`/`project`/`visibility` to `save_memory` |
| `lib/acs/memory/guidance.ex` | `generate/2` accepts caller attrs and passes to underlying `Search.list/2` |
| `lib/acs/memory/hybrid_search.ex` | Add team/project to scope scoring weight |

### Save-Time: Who Sets team/project/visibility?

`save_memory` and `document_create` MCP tools accept optional `team`, `project`,
`visibility` params. Default to `nil`/`nil`/`"org"` if absent. The caller (agent)
specifies them.

### v3 Drops vs v2

- ❌ `lib/acs/memory/visibility.ex` post-hoc filter module
- ✅ Query-level `WHERE` clauses with visibility-driven logic
- ❌ `team IS NULL` implicit org-wide fallback — replaced by explicit `visibility: "org"`

---

## Phase 5 — `ask` Tool with Structured Params (v2 #3)

**Goal:** A query tool for collaborators. **No server-side NL parsing** — the client AI
translates human queries to structured params.

### New File: `lib/acs/mcp/tools/query_agent.ex`

```elixir
defmodule Acs.MCP.Tools.QueryAgent do
  def ask(%{
    "kind" => kind,           # optional
    "team" => team,           # optional
    "project" => project,     # optional
    "content_query" => query, # optional full-text
    "document_type" => dtype, # optional
    "limit" => limit           # optional, default 10
  } = args) do
    # 1. Extract _auth_allowed_teams/_auth_allowed_projects from args
    # 2. Query memories via Indexer with ABAC predicates
    # 3. Query documents via Cognition.Search with same predicates
    # 4. Query AgentStatus table if kind in ["context", "status"]
    # 5. Merge + format as markdown response
  end
end
```

### Tool Definition (in `lib/acs/mcp/tools.ex`)

```elixir
tool_def("ask",
  "Query the org knowledge base. Specify structured filters to find memories, " <>
  "documents, or current team status. You (the client) are responsible for " <>
  "translating the human's natural language request into these parameters.",
  %{
    "kind" => %{"type" => "string", "description" => "Memory kind: context, status, work_note, activity, observation, ..."},
    "team" => %{"type" => "string", "description" => "Team scope filter"},
    "project" => %{"type" => "string", "description" => "Project scope filter"},
    "content_query" => %{"type" => "string", "description" => "Full-text search string"},
    "document_type" => %{"type" => "string", "description" => "Document type: policy, process, guideline, reference, spec"},
    "limit" => %{"type" => "integer", "description" => "Max results (default 10)"}
  },
  []
)
```

### Role Visibility

`ask` tool roles: `["collaborator", "admin"]` — available to all authenticated users.

### v3 Drops vs v2

- ❌ Server-side regex intent parser
- ❌ LLM fallback via `Acs.LLM` for query parsing
- ❌ `QUERY_LLM_URL` env var

---

## Phase 6 — Auth: API Keys + OAuth-Ready Chain

**Goal:** All org members authenticate via API key (header or query param), with an
OAuth extension point for future SSO.

### Current State (Verified Against Code)

- `MCPAuth.extract_key/1` (mcp_auth.ex:52-56) already checks `X-API-Key` header first,
  falls back to `conn.query_params["api_key"]` — query-param auth already works.
- Strategy chain via `auth_strategies/0` default `[Developer, Default]`.

### Changes

| File | Change |
|------|--------|
| `lib/acs/developers/developer_api_key.ex` | Add `allowed_teams`, `allowed_projects` fields; add `collaborator` to `validate_inclusion(:role, ...)` |
| `lib/acs/mcp/plugs/strategies/developer.ex` | Return `allowed_teams`/`allowed_projects` from the authenticated key in the result map |
| `lib/acs/mcp/plugs/mcp_auth.ex` | Pass `allowed_teams`/`allowed_projects` to `conn.assigns`; append `OAuthBearer` to strategy chain |
| `lib/acs/mcp/plugs/strategies/oauth_bearer.ex` | **NEW** placeholder strategy returning `{:error, :not_implemented}` |
| `config/runtime.exs` or `config/config.exs` | Append `Acs.MCP.Plugs.Strategies.OAuthBearer` to `auth_strategies` (before `Default` fallback) |

### Final Auth Strategy Chain

1. `Acs.MCP.Plugs.Strategies.Developer` (existing — API key via header OR query param)
2. `Acs.MCP.Plugs.Strategies.OAuthBearer` (NEW placeholder)
3. `Acs.MCP.Plugs.Strategies.Default` (existing fallback — dev mode)

---

## Phase 7 — Person-Based Agent System

**Goal:** Use person names as `agent_id`s. No structural changes — the agent system
already works with arbitrary string `agent_id`s.

### Changes

| File | Change |
|------|--------|
| Guidance/tool descriptions | Update wording to describe agents as representing team members |
| `lib/acs/mcp/tools/memory_handlers.ex` | `created_by` already uses `Acs.Cluster.developer_name()` which maps to the authenticated API key's `developer_name`. Person identity flows through naturally. |

---

## Phase 8 — Document Editing Presence & Conflict Handling (updates #2, #3, #4)

**Goal:** Awareness-only editing presence (no locking), Last Write Wins conflict
resolution, and auto-generated conflict event memories.

### Document Editing Presence Signal (update #2)

Add to `Acs.Cognition.Entry` struct (in-memory only; persisted in frontmatter):

```elixir
editing_by: [String.t()],              # list of users currently editing
last_edit_heartbeat: String.t() | nil  # ISO8601 timestamp
```

Stored in markdown frontmatter:

```yaml
---
...
editing_by:
  - alice
last_edit_heartbeat: 2026-06-30T12:34:56Z
---
```

**MCP tool `document_begin_edit`** (new):
- Args: `document_id`, `user`
- Appends `user` to `editing_by`, sets `last_edit_heartbeat` to now
- Returns warning if others are editing:

```text
Warning:
Alice is currently editing this document.
Last activity: 45 seconds ago.
```

**MCP tool `document_heartbeat`** (new):
- Args: `document_id`, `user`
- Updates `last_edit_heartbeat` to now
- Caller is expected to send periodically (e.g. every 30s)

No locking. No blocking. Awareness only.

### Document Conflict Handling (update #3)

**Policy: Last Write Wins** (for MVP).

`document_update` writes unconditionally, overwriting any concurrent edit. Captures
metadata for future optimistic concurrency:

```yaml
version: 4
updated_by: bob
updated_at: 2026-06-30T14:00:00Z
```

### Conflict Event Memories (update #4)

When `document_update` detects `version` in the incoming request is **stale** (client
sent version=3, current is 4):

1. Proceed with Last Write Wins (new version=5)
2. **Auto-create a memory** of kind `activity`:

```yaml
---
id: <auto>
kind: activity
status: approved
title: Document conflict detected
content: |
  Document: auth_policy.md
  Editors: Alice, Bob
  Winner: Bob (last write)
team: engineering
project: acs
visibility: team
sha256: ...
created_by: system
created_at: 2026-06-30T14:00:00Z
---
```

This `activity` memory bypasses auditor/embedding (per Phase 2 routing), providing
auditability without polluting indexes.

### Changes

| File | Change |
|------|--------|
| `lib/acs/cognition/entry.ex` | Add `editing_by`, `last_edit_heartbeat` fields |
| `lib/acs/cognition/loader.ex` | Serialize/deserialize new fields |
| `lib/acs/cognition/tools.ex` | Add `document_begin_edit`, `document_heartbeat` tools; add conflict-detection + auto-memory-creation logic to `document_update` |
| `lib/acs/mcp/tools.ex` | Register new tools in dispatch map |

---

## Phase 9 — Value Auditing Agent (update #5)

**Goal:** A new agent that detects contradictory memories, superseded decisions, stale
context, and conflicting observations. Recommends action; **human approval required** —
no automatic deletion.

### New File: `lib/acs/memory/value_auditor.ex`

A background GenServer (similar pattern to `Acs.Memory.Auditor`):

```elixir
defmodule Acs.Memory.ValueAuditor do
  use GenServer
  # Periodically (configurable, default 5 min):
  # 1. For each memory of kind decision/invariant/warning/axiom:
  #    - Find semantically similar memories (cosine > 0.75) across the index
  #    - Check for contradicting content (LLM eval via Acs.LLM)
  # 2. Detect status memories for completed projects (mark stale)
  # 3. Detect superseded decisions (newer decision at same scope)
  # 4. Produce recommendations as proposed-status memories with kind=warning
end
```

### Detection Examples

**Contradiction:**
```text
Potential contradiction detected

Memory 123 (decision, approved):
"Project blocked by vendor X"

Memory 456 (observation, approved):
"Vendor X issue resolved"

Suggested action:
Mark Memory 123 superseded
```

**Superseded decision:**
```text
Superseded decision detected

Memory 789 (decision, approved, 2026-06-01):
"Use database A"

Memory 890 (decision, approved, 2026-06-15):
"Use database B"

Suggested action:
Mark Memory 789 superseded
```

### Output

Recommendations are written as **new memories** (kind: `warning`, status: `proposed`)
that flow through the normal auditor pipeline — humans review and approve/reject them.
The linked memories are NOT modified by the value auditor; only the recommendation is
created. Human approval required for any action.

### LLM Usage

Reuses the existing `Acs.LLM` provider chain (nim → mimo → minimax) with circuit
breaker, timeouts, retries. No new HTTP plumbing.

### Value Alignment Review Prompt (Loaded from File)

The existing `Acs.LLM.build_evaluation_prompt/2` at `llm.ex:254` hardcodes its
prompt. The value auditor needs a **different** prompt ("value alignment review")
that can be easily edited by humans without redeploying.

Design:

- `VALUE_AUDITOR_PROMPT_PATH` env var points to a `.md` or `.txt` file
- If the path is inside the Obsidian vault, the prompt is editable in Obsidian
- On startup and periodically thereafter (e.g. every 5 min), the value auditor
  re-reads the prompt file — changes take effect without restart
- Fallback: if the file is unreadable, use a hardcoded default prompt
- The prompt file uses simple markdown with template variables:
  ```
  You are a value alignment auditor. Evaluate memory entries for contradictions,
  superseded decisions, and stale context.

  {"memory_entry": {{memory_json}}}

  {"related_memories": {{related_json}}}

  Respond ONLY with valid JSON...
  ```
  Template variables `{{memory_json}}` and `{{related_json}}` are substituted at
  call time (injection-safe via `Jason.encode!`).

`lib/acs/memory/value_auditor.ex`:
```elixir
@prompt_path Application.get_env(:steward_acs, :value_auditor_prompt_path)

defp load_prompt do
  case File.read(@prompt_path) do
    {:ok, template} -> template
    {:error, _} -> @default_prompt
  end
end
```

`@default_prompt` is the hardcoded fallback.

### Changes

| File | Change |
|------|--------|
| `lib/acs/memory/value_auditor.ex` | **NEW** GenServer; loads prompt from file with fallback |
| `lib/acs/application.ex` | Add `ValueAuditor` to supervision tree (after Auditor) |
| `config/runtime.exs` | `VALUE_AUDITOR_INTERVAL` (default 300000ms); `VALUE_AUDITOR_PROMPT_PATH` (default nil → uses hardcoded fallback) |

---

## Phase 10 — Content Hashing (update #9)

**Goal:** Skip reindexing and embedding generation for unchanged files.

### Schema

`lib/acs/memory/schema.ex`:
```elixir
field :sha256, :string
```

`lib/acs/cognition/entry.ex`:
```elixir
sha256: String.t() | nil
```

### Workflow

`lib/acs/memory/indexer.ex` — `upsert_memory_file/1` (new incremental function):

```elixir
def upsert_memory_file(file_path) do
  content = File.read!(file_path)
  hash = :crypto.hash(:sha256, content) |> Base.encode16()
  existing = get_by_file_path(file_path)
  if existing && existing.sha256 == hash do
    :skip  # no change
  else
    # parse + upsert + (if embeddable kind) generate embedding
    memory = Loader.load_file(file_path)
    upsert_memory(%{memory | sha256: hash})
    if memory.kind in @embeddable_kinds, do: Embedding.embed_single_memory(memory)
  end
end
```

### Benefits

- Saves embedding API calls (Ollama) for unchanged files
- Makes incremental file watcher upserts cheap — the common case becomes a hash compare
  + return

### Changes

| File | Change |
|------|--------|
| `lib/acs/memory/schema.ex` | Add `sha256` field |
| `lib/acs/memory/memory.ex` | Add `sha256` to defstruct + `to_yaml_map/1` |
| `lib/acs/memory/indexer.ex` | Compute + compare hash in `upsert_memory_file/1`; skip if match |
| `lib/acs/cognition/entry.ex` | `sha256` field (already listed in Phase 3) |

---

## Files Summary

### Create

| # | File | Phase |
|---|------|-------|
| 1 | `lib/acs/memory/frontmatter.ex` | 1 |
| 2 | `lib/acs/memory/lifecycle.ex` | 2 |
| 3 | `lib/acs/mcp/tools/query_agent.ex` | 5 |
| 4 | `lib/acs/mcp/plugs/strategies/oauth_bearer.ex` | 6 |
| 5 | `lib/acs/cognition/document_chunk.ex` | 3 |
| 6 | `lib/acs/memory/value_auditor.ex` | 9 |

### Modify

| # | File | Change | Phase |
|---|------|--------|-------|
| 7 | `lib/acs/memory/memory.ex` | Add 4 kinds to `@kind_types`; `@max_memory_paragraphs` validation; default status for temporal kinds; add `team`/`project`/`visibility`/`sha256` to defstruct, `new/1`, `to_yaml_map/1`; strip `.md` in `derive_scope_from_path/1` | 1, 2, 4, 10 |
| 8 | `lib/acs/memory/schema.ex` | Add `team`/`project`/`visibility`/`sha256` columns + cast list; add 4 kinds to `validate_inclusion` | 2, 4, 10 |
| 9 | `lib/acs/memory/loader.ex` | Runtime `memory_dir/0`; extension-aware reads; `.obsidian/` exclusion; `memories/` subfolder paths; config-gated write format; frontmatter dispatch | 1 |
| 10 | `lib/acs/memory/indexer.ex` | `upsert_memory_file/1` incremental + hash compare; ABAC visibility-driven `WHERE` clauses | 1, 4, 10 |
| 11 | `lib/acs/memory/file_watcher.ex` | `.md` events; `/.obsidian/` exclusion; 1000ms debounce; incremental upsert | 1 |
| 12 | `lib/acs/memory/auditor.ex` | `@auditable_kinds` filter to skip `context`/`status`/`activity` | 2 |
| 13 | `lib/acs/memory/embedding.ex` | `@embeddable_kinds` filter to skip `context`/`status`/`activity` (NOT `work_note`) | 2 |
| 14 | `lib/acs/memory/hybrid_search.ex` | Team/project scope weight; pass ABAC attrs | 4 |
| 15 | `lib/acs/memory/guidance.ex` | Pass caller ABAC attrs to underlying search; `cognition_*` → `document_*` tool refs | 4, 3 |
| 16 | `lib/acs/cognition/entry.ex` | Add `document_type`/`content`/`source`/`sha256`/`version`/`updated_by`/`team`/`project`/`visibility`/`editing_by`/`last_edit_heartbeat` | 3, 4, 8, 10 |
| 17 | `lib/acs/cognition/loader.ex` | Glob `**/*.{yaml,yml,md}`; `documents/` subfolder; dispatch `.md` via `Frontmatter.split/1`; serialize new fields | 1, 3 |
| 18 | `lib/acs/cognition/tools.ex` | Rename MCP tools `cognition_*` → `document_*`; add new fields to `@allowed_fields`; add `document_begin_edit`/`document_heartbeat`; conflict detection + memory creation in `document_update` | 3, 8 |
| 19 | `lib/acs/mcp/tools.ex` | Register `ask`; update dispatch map for `document_*`; register `document_begin_edit`/`document_heartbeat` | 3, 5, 8 |
| 20 | `lib/acs/mcp/protocol.ex` | Inject `_auth_allowed_teams`/`_auth_allowed_projects` into args | 4 |
| 21 | `lib/acs/mcp/plugs/mcp_auth.ex` | Pass ABAC attrs to `conn.assigns`; append `OAuthBearer` to strategy chain | 4, 6 |
| 22 | `lib/acs/mcp/plugs/strategies/developer.ex` | Return `allowed_teams`/`allowed_projects` in result | 4 |
| 23 | `lib/acs/mcp/tools/memory_handlers.ex` | Extract ABAC attrs from args, pass to Indexer; `save_memory` accepts `team`/`project`/`visibility`; paragraph count validation message | 4 |
| 24 | `lib/acs/developers/developer_api_key.ex` | Add `allowed_teams`/`allowed_projects`; `collaborator` role | 4, 6 |
| 25 | `lib/acs/memory/tool_guidance.ex` | `cognition_*` → `document_*` refs; add `ask` + `document_begin_edit` tool guidance | 3, 5, 8 |
| 26 | `lib/acs/application.ex` | Add `ValueAuditor` to supervision tree (after `Auditor`) | 9 |
| 27 | `config/runtime.exs` | Add `MEMORY_STORE`, `OBSIDIAN_VAULT_PATH`, `VALUE_AUDITOR_INTERVAL`, `VALUE_AUDITOR_PROMPT_PATH`; append `OAuthBearer` to auth strategies | 1, 6, 9 |

### No Changes Needed

| Module | Reason |
|--------|--------|
| `vector_index.ex` | Kind-agnostic; temporal kinds simply have no embeddings |
| `search.ex` | Delegates to hybrid search/indexer which handle new fields |
| `conflict.ex` | Tag-based conflict detection unchanged |
| `cluster.ex` | Cluster identity unchanged |
| `llm.ex` | Reused by ValueAuditor unchanged |
| `tool_registry.ex` | Role filtering works; `ask`/`document_*` roles set at registration |
| `tool_builder.ex` | Declarative macros unchanged |
| `bridge.ex` | External API bridge unchanged |
| `http_server.ex` | MCPAuth already handles query-param API keys |

---

## Implementation Order

1. **Phase 1** (Loader + Frontmatter + folder structure) — foundation
2. **Phase 2** (Temporal kinds + pipeline routing + lifecycle) — depends on Phase 1
3. **Phase 10** (Content hashing) — depends on Phase 1 incremental upsert
4. **Phase 4** (ABAC visibility-driven queries + developer schema) — depends on Phase 1 fields
5. **Phase 3** (Cognition fields + tool rename + DocumentChunk schema + document metadata) — depends on Phase 1 Frontmatter + Phase 4 ABAC
6. **Phase 6** (Auth chain + OAuthBearer) — depends on Phase 4 developer schema
7. **Phase 5** (`ask` tool) — depends on Phase 4 ABAC + Phase 3 document search
8. **Phase 8** (Document editing presence + conflict handling + conflict memories) — depends on Phase 3
9. **Phase 9** (Value auditing agent) — depends on Phase 2 + Phase 4
10. **Phase 7** (Person-based agents) — cosmetic, no deps

---

## Verification

1. `mix compile` — no warnings or errors
2. `mix ecto.reset` — DB recreated with new schema columns + kinds (no migration files)
3. `mix test test/acs/memory/` — existing tests pass
4. `mix test test/acs/cognition/` — all pass (module name unchanged)
5. `mix test test/acs/mcp/` — MCP handler tests pass
6. New tests:
   - `Frontmatter.split/1`: round-trip parse, malformed input, body-with-`---` handling
   - Loader: `.md` read/write; `memories/` vs `documents/` paths; `.obsidian/` exclusion
   - FileWatcher: 1000ms debounce; incremental upsert (changed file only)
   - Auditor: temporal kinds not audited; `work_note` audited
   - Embedding: `context`/`status`/`activity` not embedded; `work_note` embedded
   - Lifecycle: retention policy lookup; archive-due detection
   - Indexer: ABAC visibility-driven `WHERE` clause
   - Indexer: sha256 hash skip for unchanged files
   - Memory.validate: paragraph-count enforcement (>5 rejected)
   - QueryAgent: structured param dispatch
   - DocumentEditing: presence signal; conflict → memory created
   - ValueAuditor: contradiction detection (mock LLM)
   - OAuthBearer: returns `{:error, :not_implemented}`
7. `grep -r "cognition_"` in `lib/acs/mcp/` returns zero matches (tool names renamed);
   `grep -r "Acs.Cognition"` still matches (module name kept)

### Manual Smoke Test

```bash
MEMORY_STORE=obsidian OBSIDIAN_VAULT_PATH=/path/to/vault mix ecto.reset
MEMORY_STORE=obsidian OBSIDIAN_VAULT_PATH=/path/to/vault mix phx.server
# save_memory (short) → verify .md file in vault/memories/...
# save_memory (long, >5 paragraphs) → verify rejection message
# document_create → verify .md file in vault/documents/...
# Confirm .obsidian/ events don't trigger re-sync
# Confirm collaborator API key can call `ask` but not `save_memory`
# Confirm temporal kinds skip auditor + embedding (status stays "approved")
# Confirm work_note IS embedded
# Confirm conflict on document_update → activity memory created
# Confirm value auditor detects contradictions (mock test)
# Confirm unchanged file (same sha256) → no reindex on next watcher event
```