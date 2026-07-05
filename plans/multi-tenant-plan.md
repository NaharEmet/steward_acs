# Multi-Tenant Plan for Steward ACS

Single codebase, two builds: **OSS** (SQLite, single org) and **Cloud** (PostgreSQL, N orgs).

## Naming

| Term | Meaning | Example |
|------|---------|---------|
| `org` | Tenant identifier (renamed from `cluster`) | `"acme_corp"`, `"default"` |
| `team` | ABAC sub-org scope (existing on memories) | `"engineering"`, `"design"` |
| `project` | ABAC project within team (existing) | `"steward"`, `"portal"` |

## 1. Data Model

### 1.1 Rename `cluster` → `org`

| Table | Current column | New column |
|-------|---------------|------------|
| `acs_tasks` | `cluster` | `org` |
| `acs_file_locks` | `cluster` | `org` |
| `acs_agent_status` | `cluster` | `org` |
| `log_entries` | `cluster` | `org` |
| `acs_developer_api_keys` | `cluster` | `org` |

### 1.2 Add `org` to tables that lack it

| Table | Action |
|-------|--------|
| `acs_memories` | Add `org` column (default `"default"`) |
| `acs_tool_operations` | Add `org` column (default `"default"`) |
| `task_completion_feedback` | Add `org` column (default `"default"`) |
| `users` | Add `org` column (default `"default"`) |
| `users_tokens` | Add `org` column (default `"default"`) |

All `org` columns: `:string`, default `"default"`, indexed.

### 1.3 `orgs` table (optional)

```sql
CREATE TABLE orgs (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  slug TEXT NOT NULL UNIQUE,
  obsidian_vault_path TEXT,
  obsidian_sync_enabled BOOLEAN DEFAULT false,
  plan TEXT DEFAULT 'free',
  inserted_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
```

## 2. Module Rename

| Old | New |
|-----|-----|
| `Acs.Cluster` | `Acs.Org` |

```elixir
defmodule Acs.Org do
  def current, do: Application.get_env(:steward_acs, :org_name, "default")
  def filter, do: current()
  def developer_name, do: Application.get_env(:steward_acs, :developer_name, "unknown")
  def project_name, do: Application.get_env(:steward_acs, :project_name, "")
end
```

Env var: `ACS_CLUSTER_NAME` → `ACS_ORG_NAME` (keep old as fallback).

~15 callers to update across the codebase.

## 3. Vault Layout

```
OBSIDIAN_VAULT_PATH=/vaults

/vaults/
  ├── acme_org/
  │   ├── private/memories/**/*.md
  │   └── specs/**/*.yaml
  ├── big_corp/
  │   └── ...
  └── (auto-discovered — any subdirectory = an org)
```

OSS: `/vaults/default/private/memories/`
Cloud: `/vaults/<org_slug>/private/memories/`

### Memory dir resolution

```elixir
def memory_dir do
  base = Application.get_env(:steward_acs, :obsidian_vault_path)
  if multi_tenant?(), do: base, else: Path.join(base, "private/memories")
end
```

### Org extraction from path

```elixir
def extract_org(path) do
  vault_base = Application.get_env(:steward_acs, :obsidian_vault_path)
  relative = Path.relative_to(path, vault_base)
  [org_slug | _] = Path.split(relative)
  org_slug
end
```

## 4. Sync Architecture (Two-Layer, 30s)

Both layers write to DB with `org_id` derived from the path.

| Layer | Mechanism | Latency | Purpose |
|-------|-----------|---------|---------|
| **FileWatcher** (existing) | inotify on `/vaults/` | Near-instant | Live edits by users |
| **VaultSweeper** (new) | `Process.send_after`, 30s interval | 30s | Full scan, catches missed events, handles NFS |

### FileWatcher changes

Current: watches `<vault>/private/memories/`
Cloud: watches `<vault>` (the parent). Filters on `.md`/`.yaml`/`.yml` events, extracts org from path.

### VaultSweeper (new module)

```elixir
defmodule Acs.Vault.Sweeper do
  use GenServer
  @interval 30_000

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def init(_) do
    schedule_next()
    {:ok, %{}}
  end

  def handle_info(:tick, state) do
    scan_all_vaults()
    schedule_next()
    {:noreply, state}
  end

  defp scan_all_vaults do
    for org_dir <- list_org_dirs() do
      org = Path.basename(org_dir)
      # Walk *.md files in org_dir/private/memories/
      # Upsert to DB with org = org
    end
  end
end
```

Follows the same `Process.send_after` pattern as Sweeper (60s), Auditor (30s), LogAnalyzer (60s).

## 5. Auth: How org Reaches Handlers

```
Request → MCPAuth plug
  → Developer:   org from key's cluster field (now `org`)
  → OAuthBearer: org from JWT claim (NOT Acs.Org.current())
  → AppAuth:     org_id in response (already works)
  → Default:     org from Acs.Org.current() (OSS only)
  → conn.assigns.agent_org_id (already exists)
  → Protocol.handle_message(params, role, org_id, permissions, ...)
  → handler scopes queries by org
```

## 6. Storage Model

| Aspect | OSS | Cloud |
|--------|-----|-------|
| Database | SQLite | PostgreSQL |
| Canonical store | Files | Files |
| DB role | Index (search) | Index (search) |
| Org isolation | None (single "default") | `org` column on every row |
| Vault writes (user) | Instant via FileWatcher | Instant via FileWatcher |
| Memory writes (agent) | To file (current) | To DB only |
| DB rebuild | On boot + FileWatcher | On boot + FileWatcher + 30s sweep |
| Auth | Developer keys + basic | AppAuth / OAuth / Developer keys |
| Dashboard users | Global | Scoped per org |

## 7. Implementation Order

| Step | What | Files Touched |
|------|------|---------------|
| 1 | Migration: rename `cluster`→`org` on 5 tables | `priv/repo/migrations/` |
| 2 | Migration: add `org` to 5 tables | `priv/repo/migrations/` |
| 3 | Rename `Acs.Cluster` → `Acs.Org` | `lib/acs/cluster.ex` + ~15 callers |
| 4 | Create `MULTI_TENANT` config flag | `config/runtime.exs` |
| 5 | Update `Loader.memory_dir/0` for multi-org | `lib/acs/memory/loader.ex` |
| 6 | Update FileWatcher for org subfolder paths | `lib/acs/memory/file_watcher.ex` |
| 7 | Create `Acs.Vault.Sweeper` (30s) | `lib/acs/vault/sweeper.ex` |
| 8 | Add to supervision tree (cloud only) | `lib/acs/application.ex` |
| 9 | Add `org` to memory schema + indexer | `lib/acs/memory/schema.ex`, `indexer.ex` |
| 10 | Thread org through MCP Protocol → handlers | `lib/acs/mcp/protocol.ex`, all tool handlers |
| 11 | Scope all Repo queries by org | `lib/acs/acs.ex`, memory search, logs, specs |
| 12 | Dashboard user per-org scoping | `lib/acs/accounts.ex`, `user_auth.ex` |
| 13 | Dockerfiles + docs for both modes | `docker-compose.*.yml`, `README.md` |

## 8. Key Design Decisions

1. **One vault folder, org as subfolder** — single mount point, zero config per org
2. **FileWatcher + 30s VaultSweeper** — belt-and-suspenders for reliable sync
3. **DB is index, files are canonical** — vault is user workspace, DB is query layer
4. **Agent writes go to DB only** — no circular sync, vault is read-only source
5. **`org` replaces `cluster` cleanly** — no dual-column scheme, backward compatibility via default `"default"`

## 9. OSS vs Cloud Feature Table

| Feature | OSS | Cloud |
|---------|-----|-------|
| `MULTI_TENANT` | `false` | `true` |
| `REPO_ADAPTER` | `sqlite` | `postgres` |
| `MEMORY_STORE` | `yaml` | `yaml` (or `db`) |
| `ORG_NAME` | `default` | Per org |
| Vault path | Single vault | `OBSIDIAN_VAULT_PATH` as parent |
| FileWatcher | Active (single dir) | Active (parent dir) |
| VaultSweeper | Disabled | Active (30s) |
| `org` scoping | No-op (all = `default`) | Enforced on every query |
