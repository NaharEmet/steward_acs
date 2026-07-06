# Subdomain-Based Multi-Tenancy Plan

Each company gets a dedicated URL via subdomain (e.g., `acme.stewardacs.xyz`).

## Key Decisions

| Decision | Choice |
|----------|--------|
| **Dashboard login** | Strict per-subdomain — each subdomain has its own users |
| **Org provisioning** | Admin API only — no auto-provisioning |
| **Key org validation** | Key scoped to subdomain — key only works from matching subdomain |
| **OAuth org** | Subdomain-asserted (Option B) — JWT validates user, subdomain determines org |
| **Deployment model** | Single app instance + per-org vault subdirectories (Option 1) |

---

## 1. Subdomain → Org Resolution

New plug `AcsWeb.Plugs.ResolveOrg` extracts the org slug from the subdomain:

```
acme.stewardacs.xyz  →  org = "acme"
stewardacs.xyz       →  org = "default"
```

**File:** `lib/acs_web/plugs/resolve_org.ex` (new)

```elixir
def call(conn, _opts) do
  subdomain = extract_subdomain(conn)
  org = Acs.Org.from_subdomain(subdomain)
  assign(conn, :current_org, org)
end
```

Runs in both MCP pipeline (`endpoint.ex`) and dashboard pipeline (`router.ex`).

---

## 2. Deployment Architecture (Option 1)

Single Phoenix app instance. Per-org vaults as subdirectories. One postgres DB.

```
┌─────────────────────────────────────────────────────┐
│  Server                                              │
│                                                      │
│  Caddy (wildcard routing)                            │
│  *.stewardacs.xyz ──→ steward_acs:4001               │
│                                                      │
│  steward_acs (single Phoenix instance)               │
│  ├── reads /vaults/<org>/private/memories/           │
│  ├── all queries scoped by org column                │
│  └── single postgres DB                              │
│                                                      │
│  syncthing (per-org containers, one per org)          │
│  ├── syncthing_acme  → /vaults/acme/   (port 8384)   │
│  ├── syncthing_bigcorp → /vaults/bigcorp/ (port 8385)│
│  └── per-org, isolated auth                          │
│                                                      │
│  git-sync (sidecar, loops over org dirs)             │
│  ├── periodically: git add + commit + push           │
│  │   for each /vaults/<org>/                         │
│  └── per-org git remotes configured                  │
│                                                      │
│  postgres (single DB, org column isolates)           │
│                                                      │
│  Filesystem:                                         │
│  /vaults/                                            │
│  ├── acme/private/memories/  ← git repo A           │
│  ├── acme/specs/                                     │
│  ├── bigcorp/private/memories/ ← git repo B         │
│  └── bigcorp/specs/                                  │
└─────────────────────────────────────────────────────┘
```

### docker-compose.multitenant.yml

```yaml
services:
  caddy:
    image: caddy:2-alpine
    container_name: steward_caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
    environment:
      DOMAIN: "*.stewardacs.xyz"
      ACS_URL: "http://steward_acs:4001"

  steward_acs:
    build:
      context: .
      dockerfile: Dockerfile
      target: release
    image: steward_acs:multitenant
    container_name: steward_acs
    restart: unless-stopped
    expose:
      - "4001"
    environment:
      MIX_ENV: prod
      PORT: "4001"
      MULTI_TENANT: "true"
      REPO_ADAPTER: postgres
      DATABASE_URL: "ecto://${DB_USER}:${DB_PASSWORD}@db:5432/${DB_NAME:-acs_prod}"
      SECRET_KEY_BASE: "${SECRET_KEY_BASE}"
      OBSIDIAN_VAULT_PATH: /vaults     # ← parent of all org vaults
      MEMORY_STORE: obsidian
      OAUTH_BEARER_ENABLED: "${OAUTH_BEARER_ENABLED:-false}"
      AUTH0_DOMAIN: "${AUTH0_DOMAIN}"
      AUTH0_AUDIENCE: "${AUTH0_AUDIENCE}"
      MCP_PUBLIC_URL: "${MCP_PUBLIC_URL:-https://*.stewardacs.xyz}"
      ACS_USERNAME: "${ACS_USERNAME:-admin}"
      ACS_PASSWORD: "${ACS_PASSWORD}"
      MCP_API_KEY: "${MCP_API_KEY}"
    volumes:
      - vaults:/vaults       # ← all org vaults
      - acs_data:/app/priv
    depends_on:
      db:
        condition: service_healthy

  # Per-org syncthing instances (one per org, isolated auth)
  syncthing_acme:
    image: syncthing/syncthing:latest
    container_name: syncthing_acme
    hostname: syncthing_acme
    user: root
    restart: unless-stopped
    ports:
      - "127.0.0.1:8384:8384"
      - "22000:22000"
      - "21027:21027/udp"
    volumes:
      - syncthing_config_acme:/var/syncthing/config
      - vaults:/var/syncthing/vaults/acme
    environment:
      STGUIAPIKEY: "${ACME_SYNC_API_KEY}"

  syncthing_bigcorp:
    image: syncthing/syncthing:latest
    container_name: syncthing_bigcorp
    hostname: syncthing_bigcorp
    user: root
    restart: unless-stopped
    ports:
      - "127.0.0.1:8385:8384"
      - "22001:22000"
      - "21028:21027/udp"
    volumes:
      - syncthing_config_bigcorp:/var/syncthing/config
      - vaults:/var/syncthing/vaults/bigcorp
    environment:
      STGUIAPIKEY: "${BIGCORP_SYNC_API_KEY}"

  git-sync:
    build:
      context: ./docker
      dockerfile: Dockerfile.git-sync
    container_name: steward_gitsync
    restart: unless-stopped
    volumes:
      - vaults:/vaults
      - git_keys:/root/.ssh  # SSH keys for git push per org
    environment:
      INTERVAL_SECONDS: 300  # sync every 5 min
      ORG_DIRS: "acme,bigcorp"
    # Loops over each org dir, git add/commit/push

  db:
    image: postgres:16-alpine
    container_name: steward_acs_db
    restart: unless-stopped
    environment:
      POSTGRES_USER: "${DB_USER:-postgres}"
      POSTGRES_PASSWORD: "${DB_PASSWORD}"
      POSTGRES_DB: "${DB_NAME:-acs_prod}"
    volumes:
      - postgres_data:/var/lib/postgresql/data

volumes:
  vaults:
  acs_data:
  caddy_data:
  syncthing_config_acme:
  syncthing_config_bigcorp:
  git_keys:
  postgres_data:
```

### Dockerfile.git-sync

```dockerfile
FROM alpine:latest
RUN apk add --no-cache git openssh bash
COPY git-sync.sh /usr/local/bin/
CMD ["git-sync.sh"]
```

### git-sync.sh

```bash
#!/bin/bash
# For each org directory in /vaults/<org>:
#   cd /vaults/<org>
#   git add -A
#   git diff --staged --quiet || git commit -m "auto-sync $(date -u +%Y-%m-%dT%H:%M:%SZ)"
#   git push origin main 2>/dev/null || true
while true; do
  IFS=',' read -ra ORGS <<< "$ORG_DIRS"
  for ORG in "${ORGS[@]}"; do
    DIR="/vaults/$ORG"
    if [ -d "$DIR/.git" ]; then
      cd "$DIR"
      git add -A
      git diff --staged --quiet || {
        git commit -m "auto-sync $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        git push origin main 2>/dev/null || true
      }
    fi
  done
  sleep "${INTERVAL_SECONDS:-300}"
done
```

Caddyfile — wildcard + per-org obsidian sync routing:

```
*.stewardacs.xyz, stewardacs.xyz {
    tls ...
    reverse_proxy {$ACS_URL}
}

# Per-org Obsidian sync (Syncthing web UIs)
# Each org gets: <org>.obsidian.stewardacs.xyz:80
acme.obsidian.stewardacs.xyz:80 {
    basic_auth { syncuser {$ACME_SYNC_BCRYPT_PASS} }
    reverse_proxy http://syncthing_acme:8384
}

bigcorp.obsidian.stewardacs.xyz:80 {
    basic_auth { syncuser {$BIGCORP_SYNC_BCRYPT_PASS} }
    reverse_proxy http://syncthing_bigcorp:8384
}
```

Requires: wildcard DNS `*.stewardacs.xyz → <IP>`, `*.obsidian.stewardacs.xyz → <IP>`, wildcard TLS cert (Caddy auto).

---

## 3. Infrastructure: Per-Org Setup (per new org)

Adding a new org requires:

1. **Create org record** — `INSERT INTO orgs (slug, subdomain, name) VALUES ('acme', 'acme', 'Acme Corp')`
2. **Create vault directory** — `mkdir -p /vaults/acme/private/memories /vaults/acme/specs`
3. **Init git repo** — `cd /vaults/acme && git init && git remote add origin <repo-url>`
4. **Create syncthing container** — add service to docker-compose (ex: `syncthing_acme`, port `8386`, folder `/var/syncthing/vaults/acme`)
5. **Add Caddy route** — `acme.obsidian.stewardacs.xyz:80 { ... }` with per-org basic auth password
6. **Add to git-sync ORG_DIRS** — append `acme` to the comma-separated list
7. **DNS** — already handled by wildcard `*.stewardacs.xyz` and `*.obsidian.stewardacs.xyz`

---

## 4. Endpoint Routing

```elixir
plug AcsWeb.Plugs.ResolveOrg   # Sets conn.assigns.current_org
plug :route_mcp_or_dashboard   # Existing dispatcher
```

MCP routes: `agent_org_id` comes from `ResolveOrg` (overrides key-based org). Dashboard routes: `current_org` scopes sessions + LiveViews.

---

## 5. Data Model

### 5a. Rename `cluster` → `org` (5 tables)

| Table | Current Column | New Column |
|-------|---------------|------------|
| `acs_tasks` | `cluster` | `org` |
| `acs_file_locks` | `cluster` | `org` |
| `acs_agent_status` | `cluster` | `org` |
| `log_entries` | `cluster` | `org` |
| `acs_developer_api_keys` | `cluster` | `org` |

### 5b. Add `org` column (5 tables, default `"default"`)

| Table | Notes |
|-------|-------|
| `acs_memories` | Currently has ABAC fields (team/project/visibility) but no org |
| `tool_requests` | Tool request tracking |
| `task_completion_feedback` | Agent task feedback |
| `users` | Dashboard users — scoped per org |
| `users_tokens` | Session tokens — scoped per org |

### 5c. `orgs` table (admin-provisioned only)

```sql
CREATE TABLE orgs (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  slug TEXT NOT NULL UNIQUE,
  subdomain TEXT UNIQUE,
  obsidian_vault_path TEXT,
  plan TEXT DEFAULT 'free',
  inserted_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
```

---

## 6. Module: `Acs.Cluster` → `Acs.Org`

| Old | New |
|-----|-----|
| `Acs.Cluster` | `Acs.Org` |

```elixir
defmodule Acs.Org do
  def current, do: Application.get_env(:steward_acs, :org_name, "default")

  def filter, do: current()

  def from_subdomain(subdomain) do
    case Repo.get_by(Org, subdomain: subdomain) do
      nil -> subdomain  # fallback: subdomain IS the org slug
      org -> org.slug
    end
  end

  def memory_dir(org \\ current()) do
    base = Application.get_env(:steward_acs, :obsidian_vault_path)
    if multi_tenant?(), do: Path.join(base, org), else: Path.join(base, "private/memories")
  end

  defp multi_tenant? do
    Application.get_env(:steward_acs, :multi_tenant, false)
  end
end
```

Env var: `ACS_CLUSTER_NAME` → `ACS_ORG_NAME` (keep old as fallback).

---

## 7. Auth Flow

### MCP Auth
- `ResolveOrg` runs first, sets `conn.assigns.current_org` from subdomain
- Auth strategies run second
- OAuth (Option B): extracts identity/permissions only — `org_id: nil`, falls back to `current_org`
- Developer key: validates key's org matches `current_org` (reject if mismatched)
- Default: uses `current_org`
- `conn.assigns.agent_org_id` = `result.org_id || conn.assigns.current_org`

### Dashboard Auth
- Session scoped to subdomain's org
- `fetch_current_user` scopes user lookup by `current_org`
- Login creates/authenticates user within the subdomain's org
- After login, session is tied to that org

---

## 8. Dashboard Scoping

```elixir
pipeline :browser do
  plug :accepts, ["html"]
  plug :fetch_session
  plug :fetch_live_flash
  plug :put_root_layout, html: {AcsWeb.Layouts, :root}
  plug :protect_from_forgery
  plug :put_secure_browser_headers
  plug AcsWeb.Plugs.ResolveOrg     # NEW
  plug :fetch_current_user         # scoped by current_org
end
```

LiveViews receive `current_org` in session and scope all queries.

---

## 9. Vault Layout

```
/vaults/<org_slug>/private/memories/
/vaults/<org_slug>/specs/
```

- `Acs.Org.memory_dir(org)` resolves based on org
- FileWatcher watches `/vaults/` root, extracts org from path components
- VaultSweeper (new, 30s) scans all org subdirectories

### FileWatcher changes
Current: watches single directory for `.md` files
Multi-tenant: watches `/vaults/` (the parent), filters on `.md`/`.yaml` events, extracts org from path:
```elixir
def extract_org(path) do
  vault_base = Application.get_env(:steward_acs, :obsidian_vault_path)
  relative = Path.relative_to(path, vault_base)
  [org_slug | _] = Path.split(relative)
  org_slug
end
```

---

## 10. Config Changes

| Config Key | Rename To | Default |
|------------|-----------|---------|
| `:cluster_name` | `:org_name` | `"default"` |
| `ACS_CLUSTER_NAME` | `ACS_ORG_NAME` | `"default"` |
| (new) | `MULTI_TENANT` | `false` |

Backward compat: if `ACS_CLUSTER_NAME` is set but `ACS_ORG_NAME` isn't, use cluster name.

---

## 11. Comprehensive Org-Scoping Inventory

Everything in the codebase that needs to become org-scoped, organized by category.

### 11a. Ecto Schemas — field changes

| Table | Schema Module | Has `cluster`? | Action |
|-------|---------------|----------------|--------|
| `acs_tasks` | `Acs.Acs.Task` | Yes (line 34) | Rename to `org` |
| `acs_file_locks` | `Acs.Acs.FileLock` | Yes (line 25) | Rename to `org` |
| `acs_agent_status` | `Acs.Acs.AgentStatus` | Yes (line 11) | Rename to `org` |
| `log_entries` | `Acs.Log.LogEntry` | Yes (line 23) | Rename to `org` |
| `acs_developer_api_keys` | `Acs.Developers.DeveloperApiKey` | Yes (line 18) | Rename to `org` |
| `acs_memories` | `Acs.Memory.Schema` | No | Add `org` field |
| `tool_requests` | `Acs.MCP.ToolRequest` | No | Add `org` field |
| `task_completion_feedback` | `Acs.Acs.TaskCompletionFeedback` | No | Add `org` field |
| `users` | `Acs.Accounts.User` | No | Add `org` field |
| `users_tokens` | `Acs.Accounts.UserToken` | No | Add `org` field |

### 11b. `lib/acs.ex` — Core operations that need org scoping

| Function | Issue |
|----------|-------|
| `create_task/2` (line 43) | Rename `cluster` to `org` in attrs |
| `bump_task/2` (line 76) | `Repo.get` — no org scope. Add `where org == ^org` |
| `claim_task/2` (line 105) | `Repo.get` — no org scope before claiming |
| `release_task/2` (line 152) | `Repo.get` — no org scope |
| `set_task_status/3` (line 200) | `Repo.get` — no org scope |
| `list_tasks/2` (line 240) | Has `where t.cluster == ^cluster` ✅ — rename to `org` |
| `get_task/1` (line 254) | `Repo.get` — no org scope |
| `lock_file/3` (line 284) | `Repo.get_by` — no org scope on read; insert sets cluster ✅ |
| `unlock_file/2` (line 358) | `Repo.get_by` — no org scope |
| `unlock_files_for_task/2` (line 384) | No org scope |
| `get_locked_files/1` (line 400) | Has cluster scope ✅ — rename to `org` |
| `check_file_lock/1` (line 408) | No org scope |
| `get_present_status/1` (line 425) | No org scope in task/file_lock queries |
| `get_agent_present_status/1` (line 464) | No org scope |
| `upsert_agent_status/5` (line 516) | Sets cluster ✅ — rename to `org` |
| `clear_agent_status/1` (line 546) | No org scope |
| `check_no_duplicate_title/1` (line 570) | No org scope on task lookup |

### 11c. Auth strategies — org source

| File | Current | Action |
|------|---------|--------|
| `oauth_bearer.ex` (line 44) | `org_id: Acs.Cluster.current()` | Change to `org_id: nil` (subdomain asserts org) |
| `developer.ex` (line 23,29) | `org_id: result.cluster` | Rename to `org` + validate against `current_org` |
| `default.ex` (line 14,34) | `org_id: nil` | Falls back to `current_org` ✅ |
| `app_auth.ex` (line 44) | `org_id: body["org_id"]` | Already correct — external app returns org |
| `mcp_auth.ex` (line 46-47) | Assigns `agent_org_id` + `agent_cluster` | Remove `agent_cluster`; `agent_org_id` falls back to `current_org` |

### 11d. Tool handlers — DB queries missing org scope

| Handler File | Functions Missing Org Scope |
|-------------|----------------------------|
| `core_handlers.ex` | `acs_claim_work`, `acs_release_work`, `acs_unlock_file`, `get_logs` |
| `memory_handlers.ex` | `save_memory`, `query_memories`, `set_memory_status`, `generate_guidance_packet` |
| `error_handlers.ex` | `acs_submit_task_feedback`, `list_error_traces`, `ack_error_trace`, `resolve_error_trace` |
| `diagnostic_handlers.ex` | `memory_health_check`, `count_log_clusters` |
| `query_agent.ex` | `ask` (memory + document queries) |

### 11e. Memory system — org scoping gaps

| File | Functions/Fields Missing Org |
|------|------------------------------|
| `lib/acs/memory/schema.ex` | No `org` field on `acs_memories` schema |
| `lib/acs/memory/indexer.ex` | `upsert_memory`, `remove_memory`, `update_status`, `update_field`, `get_memory`, `get_memories_by_ids`, `count_by_status`, `list_memories`, `list_memories_needing_review`, `search`, `build_abac_filter` — all missing org |
| `lib/acs/memory/loader.ex` | `memory_dir/0` returns single path — needs org awareness |
| `lib/acs/memory/search.ex` | `search/2`, `list/1` — missing org filter |
| `lib/acs/memory/guidance.ex` | `generate/2` — missing org filter |
| `lib/acs/memory/file_watcher.ex` | Watches single dir — needs to watch parent, extract org |
| `lib/acs/memory/auditor.ex` | All `Repo` operations — missing org |

### 11f. ETS systems — no org field

| System | Table/Store | Functions Missing Org |
|--------|-------------|----------------------|
| `ErrorTrace` | ETS (error traces) | `list_traces`, `ack_trace`, `resolve_trace` — no org field in entry struct |
| `LogStore` | ETS (log cache) | `get_logs`, `store_log` — no org field in ETS entries |

### 11g. LiveViews — dashboard queries missing org

| LiveView | Queries Missing Org |
|----------|---------------------|
| `acs_live/index.ex` | `list_tasks`, `get_locked_files`, `get_present_status` — some scoped, some not |
| `acs_live/memory_live.ex` | `Indexer.list_memories`, `Indexer.count_by_status`, `Search.search` — shows all orgs |
| `acs_live/specs_live.ex` | `Loader.load_all`, `Search.search` — file-based, needs org partitioning |
| `acs_live/tool_requests.ex` | `ToolRequests.list_requests` — no org scope |
| `acs_live/error_traces_live.ex` | ErrorTraces queries — ETS, no org |

### 11h. ABAC system — needs org check

| File | Issue |
|------|-------|
| `lib/acs/abac.ex` | `visible?/2`, `filter/2`, `visible_item?/2` — check team/project/visibility but NOT org |
| | Add: if caller's org doesn't match item's org, deny immediately |

### 11i. Specs system — file-based, needs org

| File | Action |
|------|--------|
| `lib/acs/specs/entry.ex` | Add `org` field to struct |
| `lib/acs/specs/loader.ex` | `load_all`, `list` — add org filter |
| `lib/acs/specs/tools.ex` | All handlers — add org scoping |
| `lib/acs/specs/search.ex` | `search/2` — add org filter |

### 11j. Accounts — user scope

| File | Functions Missing Org |
|------|----------------------|
| `lib/acs/accounts.ex` | `get_user_by_email`, `register_user`, `get_or_register_user`, `generate_user_session_token` — all need org |

### 11k. Developer keys — scope queries

| File | Functions Missing Org |
|------|----------------------|
| `lib/acs/developers/developers.ex` | `authenticate`, `list_developers`, `revoke` — no org scope on queries |

### 11l. Log system

| File | Functions |
|------|-----------|
| `lib/acs/log/log_repo.ex` | `insert_raw`, `query`, `count`, `apply_cluster_filter`, `delete_old` — rename cluster to org |

### 11m. Config/docs references to rename

| File | Lines | Current | New |
|------|-------|---------|-----|
| `config/runtime.exs` | 243 | `:cluster_name` / `ACS_CLUSTER_NAME` | `:org_name` / `ACS_ORG_NAME` |
| `config/dev.exs` | 72 | `:cluster_name` | `:org_name` |
| `docker-compose.yml` | 15 | `ACS_CLUSTER_NAME` | `ACS_ORG_NAME` |
| `docker-compose.remote.yml` | 42 | `ACS_CLUSTER_NAME` | `ACS_ORG_NAME` |
| `.env.example` | 58 | `ACS_CLUSTER_NAME` | `ACS_ORG_NAME` |
| `.env.remote` | 24 | `ACS_CLUSTER_NAME` | `ACS_ORG_NAME` |
| `bin/setup.sh` | 244 | `ACS_CLUSTER_NAME` | `ACS_ORG_NAME` |
| `README.md` | 236 | `ACS_CLUSTER_NAME` | `ACS_ORG_NAME` |
| `site/steward-acs-content.md` | 367, 389, 695 | `ACS_CLUSTER_NAME` | `ACS_ORG_NAME` |
| `site/index.html` | 465, 654, 868 | `ACS_CLUSTER_NAME` | `ACS_ORG_NAME` |
| `lib/mix/tasks/acs/keys.ex` | 13,32,37,42,78 | `--cluster` | `--org` |
| `test/acs/cluster_test.exs` | 6,9,13,16,22,25,31,34 | `:cluster_name` | `:org_name` |

### 11n. Tool operations table

| Table | Action |
|-------|--------|
| `acs_tool_operations` | Add `org` field (not tracked in previous inventory) |

---

## 12. Summary: Files to Touch by Category

| Category | Count | Examples |
|----------|-------|---------|
| New files | 4 | `resolve_org.ex`, `vault/sweeper.ex`, `Dockerfile.git-sync`, `git-sync.sh` |
| Schema changes | 10 | task, file_lock, agent_status, developer_api_key, log_entry, memory, user, user_token, tool_request, completion_feedback |
| Auth changes | 5 | `mcp_auth.ex`, `oauth_bearer.ex`, `developer.ex`, `default.ex`, `user_auth.ex` |
| Core module changes | 1 | `lib/acs.ex` (~20 functions) |
| Tool handler changes | 4 | core_handlers, memory_handlers, error_handlers, diagnostic_handlers |
| Memory system changes | 6 | schema, indexer, loader, search, guidance, file_watcher, auditor |
| ETS system changes | 2 | error_trace, log_store |
| LiveView changes | 5 | index, memory, specs, tool_requests, error_traces |
| Config/docs rename | 12+ | runtime.exs, docker-compose files, .env, README, site files |
| Other | 3 | abac.ex, accounts.ex, developers.ex, specs/, log_repo.ex |
| Deployment | 3 | Caddyfile, docker-compose.multitenant.yml, Dockerfile.git-sync |

---

## 13. Implementation Order

| Phase | Step | Description | Files |
|-------|------|-------------|-------|
| **P1** | 1 | `ResolveOrg` plug + subdomain extraction | `lib/acs_web/plugs/resolve_org.ex` |
| **P1** | 2 | Wire into endpoint.ex + router.ex | `endpoint.ex`, `router.ex` |
| **P1** | 3 | Rename `Acs.Cluster` → `Acs.Org` + `from_subdomain/1` | `lib/acs/cluster.ex` → `lib/acs/org.ex` |
| **P1** | 4 | MCP auth: wire `agent_org_id` from subdomain (Option B) | `mcp_auth.ex`, `oauth_bearer.ex` |
| **P1** | 5 | Validate developer key org against subdomain org | `developer.ex` |
| **P2** | 6 | Migration: create `orgs` table | `priv/repo/migrations/` |
| **P2** | 7 | Migration: rename `cluster`→`org` on 5 tables | `priv/repo/migrations/` |
| **P2** | 8 | Migration: add `org` to 6 tables (memories, users, tokens, tool_requests, feedback, tool_operations) | `priv/repo/migrations/` |
| **P3** | 9 | Update all Ecto schemas (rename `cluster`→`org`, add `org` fields) | All 11 schema files (see 11a) |
| **P3** | 10 | Update `lib/acs.ex` — scope all 20 functions by org | `lib/acs.ex` |
| **P3** | 11 | Update tool handlers — scope by org | core_handlers, memory_handlers, error_handlers, diagnostic_handlers |
| **P4** | 12 | Update memory system — schema, indexer, search, guidance | memory/ (6 files) |
| **P4** | 13 | Update ETS systems — ErrorTrace, LogStore add org | `error_trace.ex`, `log_store.ex` |
| **P4** | 14 | Update ABAC — add org check | `abac.ex` |
| **P5** | 15 | Dashboard: scope user sessions by org | `user_auth.ex`, `user_session_controller.ex`, `accounts.ex` |
| **P5** | 16 | Dashboard: scope LiveViews by org | All 5 LiveView modules |
| **P5** | 17 | Update specs system — add org filter | specs/ (4 files) |
| **P5** | 18 | Update developer keys — scope queries by org | `developers.ex` |
| **P5** | 19 | Update log system — rename cluster to org | `log_repo.ex`, `log_entry.ex` |
| **P6** | 20 | FileWatcher — watch parent, extract org from path | `file_watcher.ex` |
| **P6** | 21 | VaultSweeper (30s) — scan all org subdirectories | `vault/sweeper.ex`, `application.ex` |
| **P6** | 22 | `MULTI_TENANT` + `ACS_ORG_NAME` config | `config/runtime.exs` |
| **P6** | 23 | Rename all config/docs references | docker-compose, .env, README, site |
| **P7** | 24 | Caddyfile wildcard config | `Caddyfile` |
| **P7** | 25 | `docker-compose.multitenant.yml` + git-sync sidecar | Docker files |
| **P7** | 26 | Deployment docs + per-org setup checklist | `README.md`, `guides/` |
