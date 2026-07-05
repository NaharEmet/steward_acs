# Steward ACS — Agent Coordination System

> Complete content reference for building the Steward ACS website.
> Intended for Astro site builder agents. All pages, components, and data points are here.

---

## 1. BRAND & IDENTITY

| Field              | Value                                                |
| ------------------ | ---------------------------------------------------- |
| **System name**    | Steward ACS                                          |
| **Tagline**        | Coordinate your AI agents with precision             |
| **Subtitle**       | The Agent Coordination System — task lifecycles, file locking, knowledge memory, and MCP tools for AI agent infrastructure |
| **Formerly known as** | Agent Coordination System (ACS)                   |
| **Module prefix**  | `Acs.*` (internal, never user-facing)                |
| **Tool prefix**    | `acs_*` (what agents type — 3 chars, short)          |
| **Container name** | `steward_acs`                                        |
| **Mix app atom**   | `:steward_acs`                                       |
| **Language**       | Elixir (Phoenix 1.8, LiveView 1.1)                   |
| **Port**           | 4001                                                 |
| **Version**        | 0.1.0                                                |
| **License**        | Proprietary                                          |

### Brand voice
- Infrastructure-grade — precise, reliable, confident
- Stewardship metaphor — the system manages on behalf of agents
- Not magical, not hype — honest about capabilities and limits
- Developer/agent-facing, not consumer-facing

---

## 2. WHAT IS STEWARD ACS

Steward ACS is an **infrastructure layer** for AI agent coordination. It runs as a standalone Phoenix web application and exposes MCP (Model Context Protocol) tools that AI agents call directly. It does not do the work itself — it manages the agents who do.

Think of it as the **control plane** for multi-agent development: who's working on what, what files are being edited, what knowledge has been discovered, what errors need attention.

The name "Steward" comes from the Old English *stigweard* — "one who manages affairs on behalf of another." Steward ACS manages the coordination estate so agents can focus on building.

---

## 3. CAPABILITIES (What It CAN Do)

### 3.1 Task Lifecycle
- **Create tasks** with title, description, and associated file paths
- **Claim tasks** by agent — one agent per task
- **Release tasks** when work is complete
- **List tasks** filtered by status (todo, in_progress, done)
- **Automatic 10-minute timeout** — tasks auto-release if agent goes silent
- **Similarity warnings** — detects duplicate tasks before creation
- **Bump/reset timer** — extends auto-release deadline
- **File paths on tasks** — track which files a task touches

### 3.2 File Locking
- **Lock files** before editing — prevents multi-agent edit conflicts
- **Unlock files** individually or bulk by task
- **Check locks** — see every locked file across all agents
- **Auto-release** — locks expire after 10 minutes of inactivity
- **Idempotent locking** — same file, same agent, same task: no error
- **Unique constraint** — different agents cannot lock the same file

### 3.3 Agent Presence
- **Track every agent's current task** — what they're working on
- **Track purpose** — why they're working
- **Track application and component** — where they're working
- **List all agents** and their status (working, sleeping, idle)
- **Sleep/wake protocol** — idle agents sleep to save resources, wake on dispatch

### 3.4 Knowledge Memory
- **Save memories** — eternal truths that persist across agent sessions
- **Memory types**: observation, learning, warning, pattern, bug, decision, invariant, axiom
- **Full-text search** across all memories
- **Semantic search** via LLM-powered embeddings (configurable provider)
- **Status workflow** — proposed → approved → (rejected/stale/deprecated/archived)
- **Guidance packets** — contextual knowledge bundle injected when an agent claims a task
- **Scope paths** — organize memories by namespace (e.g., `auth/`, `database/`, `deployment/`)
- **Tags** — categorize memories
- **Trigger events** — associate memories with conditions
- **Importance ratings** — 1-5 priority scale

### 3.5 Cognition Spec System
- **Structured module documentation** — purpose, invariants, workflows, failure modes, constraints, tags
- **Propose specs** — new or updated documentation
- **Approve/reject** — review workflow with versions
- **Search specs** — full-text across all fields
- **List undocumented modules** — find gaps
- **Verification status** — track spec quality
- **Auto-computed spec hash** — detect stale docs

### 3.6 MCP Tool Gateway
- **Expose any REST API as an agent-callable tool** — no BEAM recompile needed
- **YAML-defined** — tools declared in `{app}.yaml` files
- **Hot-reload** — tools load without server restart
- **Internal tools** — Elixir handlers for task/lock/memory/cognition operations
- **External tools** — HTTP proxy bridge to external REST APIs
- **Tool registry** — GenServer with ETS-backed lookup
- **Progressive disclosure** — tools at levels 1-3 (basic → diagnostic → admin)
- **Role-based access** — admin, dev, analyst roles
- **Tool categories** — core, knowledge, cognition, diagnostic, cluster

### 3.7 Error Tracking
- **Persistent error traces** — runtime errors recorded in database
- **List errors** — filter by status, service, component, count
- **Acknowledge errors** — mark as being investigated
- **Resolve errors** — mark as fixed
- **Create investigation tasks** — directly from error traces
- **Error analytics** — count, frequency patterns

### 3.8 Logging & Analytics
- **Structured logging** — level, component, module, tags, workflow_id, execution_id
- **Filter logs** — by level, component, module, time range, search text
- **Log retention sweeper** — automatic cleanup of old logs
- **Compact log mode** — reduced verbosity option
- **Context window** — surrounding log context for debugging

### 3.9 Cluster Coordination
- **Multi-cluster support** — operations scoped by cluster name
- **Independent environments** — dev, staging, production in same ACS
- **Default cluster** — "default" for simple deployments
- **Cluster-scoped data** — tasks, locks, memory isolated by cluster

### 3.10 Time Management
- **Time offset** — simulate past/future timing for testing
- **10-minute auto-release** — configurable via sweeper interval
- **Task bump** — reset auto-release timer

### 3.11 Sleep Registry
- **Long-poll blocking** — idle agents sleep waiting for tasks
- **Wake on dispatch** — agent wakes when a task claims or dispatches
- **Timeout configurable** — per-agent
- **Resource efficiency** — sleeping agents consume no CPU

### 3.12 Developer API Keys
- **Generate API keys** for agents to authenticate with
- **Role-based** — admin, dev, analyst
- **Named keys** — track which agent owns which key

---

## 4. LIMITATIONS (What It CANNOT Do)

### 4.1 Not a Work Engine
- **Does not do the actual work** — agents code, research, write. Steward ACS only coordinates.
- **No built-in code generation** — agents bring their own capabilities.
- **No file editing** — agents read/write files directly. Steward ACS only prevents conflicts.
- **No build/deploy pipeline** — agents handle CI/CD themselves.

### 4.2 Not a Workflow/DAG Engine
- **No multi-step workflow definitions** — no "do X then Y then Z" sequencing.
- **No conditional branching** — task flow is agent-decided.
- **No retry logic** — if a task fails, the agent must retry.
- **No scheduled tasks** — no cron-like time-based triggering.
- **No parallelism constraints** — agents claim tasks independently; no "max 3 concurrent" limits.

### 4.3 Not a Message Queue
- **Agent-initiated dispatch** — agents claim tasks; Steward ACS does not push work.
- **No pub/sub for agents** — agents communicate through memory, not directly.
- **No real-time streaming** — agents poll for status changes.
- **No guaranteed delivery** — if no agent claims a task, it sits.

### 4.4 Not a Database
- **Memory search quality depends on LLM provider** — weak embeddings = weak search.
- **No graph queries** — memory is flat, not relational.
- **No version history** — memory overwrites, no git-like history.
- **No full-text in database** — search uses LLM embeddings + SQLite FTS5.

### 4.5 Not an LLM Provider
- **No built-in LLM** — Steward ACS integrates with external providers (MIMO, Ollama, etc.).
- **No model serving** — you bring your own LLM for memory embedding.
- **No prompt management** — agents craft their own prompts.

### 4.6 Not a Version Control System
- **File locking prevents conflicts** but does not replace Git.
- **No diff/merge** — two agents cannot edit the same file simultaneously.
- **No change history** — file locks leave no audit trail of who edited what.

### 4.7 Not a Monitoring System
- **Error traces exist** but no alert routing (PagerDuty, Slack, email).
- **No metrics dashboard** — no grafana-style visualization.
- **No uptime monitoring** — health check is basic.
- **No usage/analytics dashboard** — you build your own.

### 4.8 Not a Full Auth/Access System (for agents)
- **API keys** — primary auth for Claude Code, plugins, and service integrations.
- **Auth0 OAuth** — optional for Claude web Custom Connectors when `OAUTH_BEARER_ENABLED=true` (see `.env.remote`).
- **No SSO / enterprise IdP** beyond Auth0 for Connectors.
- **No per-agent permissions** beyond role (admin/dev/analyst).
- **No audit logging for agent actions** — only error traces.

### 4.9 Not a Distributed Coordination System (yet)
- **Single-node by default** — no Raft/Paxos consensus.
- **No leader election** — cluster is a namespace, not a distributed cluster.
- **No cross-node task migration** — tasks stay on the node where they were created.
- **No high availability** — if the node goes down, coordination halts.

### 4.10 Other Constraints
- **Phoenix dependency** — requires the Elixir/Phoenix runtime.
- **PostgreSQL production dependency** — SQLite3 for dev only.
- **No native MCP transport** — uses HTTP, not stdio.
- **Memory in-memory** — ETS cache is lost on restart (cold start).
- **No web UI for human users** — dashboard is minimal, agent-first.
- **No REST API for external tools** — only MCP tool interface.

---

## 5. ARCHITECTURE

### 5.1 System Layers

```
┌─────────────────────────────────────────────────────────────────┐
│                     AGENTS (MCP Clients)                          │
│  Call acs_* tools over HTTP to port 4001                         │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│                  STEWARD ACS (Phoenix App)                        │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │             HTTP Endpoint (Bandit)                          │  │
│  │  ┌─────────────┐  ┌──────────────┐  ┌──────────────────┐  │  │
│  │  │ MCP Gateway  │  │ Phoenix      │  │ LiveView         │  │  │
│  │  │ /mcp/*       │  │ Web          │  │ Dashboard         │  │  │
│  │  └──────┬───────┘  └──────────────┘  └──────────────────┘  │  │
│  └─────────┼──────────────────────────────────────────────────────┘
│            │
│            ▼
│  ┌────────────────────────────────────────────────────────────┐  │
│  │            Tool Dispatcher (Acs.MCP.Tools)                  │  │
│  │  ┌──────────┐ ┌──────────┐ ┌────────┐ ┌───────────────┐  │  │
│  │  │ Task     │ │ File Lock│ │ Memory │ │ Cognition     │  │  │
│  │  │ Handlers │ │ Handlers │ │Handler │ │ Handlers      │  │  │
│  │  └──────────┘ └──────────┘ └────────┘ └───────────────┘  │  │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────────────────────┐  │  │
│  │  │ Error    │ │ Log      │ │ Bridge (external tools)  │  │  │
│  │  │ Handlers │ │ Handlers │ │ → POST to REST APIs      │  │  │
│  │  └──────────┘ └──────────┘ └──────────────────────────┘  │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │       ETS Cache (In-Memory)                                 │  │
│  │  :steward_tasks  :steward_file_locks  :steward_agent_status  │  │
│  │  :steward_next_agent                                         │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │       Database                                             │  │
│  │  Tables: tasks, file_locks, agent_status, memories,        │  │
│  │          cognition_specs, error_traces, logs,               │  │
│  │          locked_files, agent_status, organizations          │  │
│  │  Dev: SQLite3   Prod: PostgreSQL                            │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │       Background Processes                                  │  │
│  │  Sweeper: auto-release stale tasks/locks after 10min        │  │
│  │  Auditor: memory quality checks (configurable interval)     │  │
│  │  RetentionSweeper: clean old logs                           │  │
│  │  MetaHarness: analysis, generation, reporting               │  │
│  └────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### 5.2 Data Flow (Agent Creates + Completes a Task)

```
1. Agent → acs_create_work(agent_id, title, file_paths)
      → Task created with status "todo"
      → Similarity check against existing tasks (warning if duplicate)
      → Returns task_id

2. Agent → acs_claim_work(agent_id, task_id)
      → Task status → "in_progress"
      → locked_by → agent_id
      → auto_release_at → now + 10min
      → Returns task + guidance packet (relevant memories)

3. Agent → acs_lock_file(agent_id, task_id, "lib/foo.ex")
      → File lock created (unique constraint on file)
      → Other agents cannot lock same file
      → Safe to edit

4. Agent → acs_save_memory(kind, title, content, scope_path)
      → Memory created with status "proposed"
      → Searchable by other agents

5. Agent → acs_release_work(agent_id, task_id)
      → Task status → "done"
      → Locks released for this task
      → Returns feedback prompt

6. Agent → acs_submit_task_feedback(task_id, learned_for_agents)
      → Knowledge memories auto-generated from learnings
      → Task lifecycle complete
```

### 5.3 Technology Stack

| Layer          | Technology                       | Notes                                |
| -------------- | -------------------------------- | ------------------------------------ |
| Language       | Elixir 1.17+                     | Functional, fault-tolerant           |
| Web framework  | Phoenix 1.8.3                    | Real-time, productive                |
| LiveView       | 1.1                              | Real-time UI without JS               |
| HTTP server    | Bandit 1.5                       | Fast, modern HTTP server             |
| Database (dev) | SQLite3 (via ecto_sqlite3 0.22)  | Zero-config local dev                |
| Database (prod)| PostgreSQL (via postgrex 0.19)   | Production-grade persistence         |
| PubSub         | Phoenix PubSub 2.2               | Agent wake/sleep notifications       |
| Caching        | ETS (Erlang Term Storage)        | In-memory, fast lookups             |
| LLM client     | Req 0.5 + ReqLLM 1.0            | HTTP client for LLM providers        |
| LLM utils      | llm_utils (LLMUtils.*)          | JSON-based LLM interaction           |
| YAML parsing   | yaml_elixir 2.9                  | Tool definitions                     |
| File watching  | file_system 1.0                  | Memory file watcher                  |
| JS bundler     | esbuild 0.21.5                   | Asset compilation                    |
| CSS            | Tailwind CSS 3.4.3               | Utility-first CSS                    |

---

## 6. QUICK START

### 6.1 Docker (Fastest)

```bash
# Prerequisites: Docker, Docker Compose
git clone <repo-url>
cd <repo>

# Generate secret key
echo "SECRET_KEY_BASE=$(mix phx.gen.secret)" >> .env

# Start everything
docker compose -f docker-compose.steward_acs.yml up -d

# Verify
curl http://localhost:4001/health
```

### 6.2 From Source

```bash
# Prerequisites: Elixir 1.17+, PostgreSQL or SQLite3
cd apps/steward_acs

# Setup
mix deps.get
mix ecto.setup  # creates + migrates database

# Run (dev)
mix phx.server

# Run tests
mix test
```

### 6.3 Docker Compose Reference

```yaml
services:
  steward_acs:
    build:
      context: .
      dockerfile: Dockerfile.steward_acs
    ports:
      - "4001:4001"
    environment:
      ACS_CLUSTER_NAME: ${ACS_CLUSTER_NAME:-dev}
      DATABASE_URL: ${DATABASE_URL:-ecto://postgres:postgres@localhost:5432/acs}
      POOL_SIZE: "10"
      SECRET_KEY_BASE: ${SECRET_KEY_BASE:-}
    volumes:
      - steward_acs_data:/app/data
    restart: unless-stopped

volumes:
  steward_acs_data:
```

---

## 7. CONFIGURATION REFERENCE

### 7.1 Environment Variables

| Variable                 | Required | Default                                                  | Description                            |
| ------------------------ | -------- | -------------------------------------------------------- | -------------------------------------- |
| `SECRET_KEY_BASE`          | **Yes**  | —                                                        | Phoenix session signing secret. Generate with `mix phx.gen.secret`. |
| `DATABASE_URL`            | **Yes**  | `ecto://postgres:postgres@localhost:5432/acs`             | Full database connection string        |
| `ACS_CLUSTER_NAME`        | No       | `default`                                                | Cluster identity. Scopes all operations. Use separate names for dev/staging/prod. |
| `ACS_DEVELOPER_NAME`      | No       | `unknown`                                                | Developer identity tag for memory creation attribution |
| `POOL_SIZE`               | No       | `10`                                                     | Database connection pool size          |
| `AUDITOR_INTERVAL`        | No       | `30000`                                                  | Memory auditor polling interval (milliseconds) |
| `MIMO_API_KEY`            | No       | `""`                                                     | API key for MIMO LLM provider (memory evaluation) |
| `ENABLED_LLM_PROVIDERS`   | No       | All configured                                           | Comma-separated whitelist (e.g., `mimo,minimax`) |
| `OLLAMA_URL`              | No       | `http://localhost:11434`                                 | URL for local Ollama instance (embeddings) |
| `MCP_API_KEY`             | No       | —                                                        | API key for MCP tool authentication    |
| `MCP_QUERY_KEY_AUTH`      | No       | `false`                                                  | Allow `?api_key=` on MCP SSE (connector fallback) |
| `OAUTH_BEARER_ENABLED`    | No       | `false`                                                  | Enable Auth0 JWT validation for Claude Connectors |
| `AUTH0_DOMAIN`            | When OAuth on | —                                                     | Auth0 tenant (e.g. `dev-jw5wgp2b.us.auth0.com`) |
| `AUTH0_AUDIENCE`          | When OAuth on | —                                                     | MCP API identifier (e.g. `https://prod.stewardacs.xyz/mcp/sse`) |
| `MCP_PUBLIC_URL`          | When OAuth on | —                                                     | Public base URL for OAuth metadata |
| `MCP_RESOURCE_URL`        | No       | same as audience                                         | Resource URL in protected-resource metadata |
| `SERVICE_API_KEY`         | No       | —                                                        | Service-level API key for integrations |
| `MCP_AUTH_LOCAL_FALLBACK` | No       | `true` (dev)                                             | Allow connections without auth on localhost |
| `ANANTHA_URL`            | No       | `http://localhost:4000`                                  | Anantha base URL (optional integration) |
| `ANANTHA_API_KEY`        | No       | —                                                        | Anantha API key (optional)             |

### 7.2 Database Configuration

**Development** (SQLite3):
- File-based: `var/acs.sqlite`
- Zero config, auto-created
- `DATABASE_PATH` env var overrides location

**Production** (PostgreSQL):
| Env Var      | Default     | Description          |
| ------------ | ----------- | -------------------- |
| `PGUSER`       | `postgres`  | Username             |
| `PGPASSWORD`   | `postgres`  | Password             |
| `PGHOST`       | `localhost` | Host                 |
| `PGPORT`       | `5432`      | Port                 |
| `PGDATABASE`   | `acs_prod`  | Database name        |
| `PGSSL`        | `false`     | Enable SSL           |
| `POOL_SIZE`    | `10`        | Connection pool      |

### 7.3 MCP Server Configuration

| Config                  | Default         | Description                           |
| ----------------------- | --------------- | ------------------------------------- |
| `enabled`               | `true`          | Enable/disable MCP server             |
| `transport`             | `:http`         | Transport protocol                    |
| `tools_paths`           | `/app/acstools/` | Directories containing YAML tool defs |
| `auth_strategies`       | `[Developer, Default]` | Authentication providers      |
| `mcp_auth_local_fallback` | `true` (dev)   | Allow fallback on localhost           |

### 7.4 Audit Config

| Env Var                   | Default   | Description                        |
| ------------------------- | --------- | ---------------------------------- |
| `AUDITOR_INTERVAL`          | `30000`   | Polling interval in ms             |
| `DEVELOPER_NAME`            | `unknown` | Attribution tag for memory entries |

### 7.5 Anantha Integration (Optional)

When Steward ACS is deployed alongside Anantha:

| Env Var            | Default                       | Description                  |
| ------------------ | ----------------------------- | ---------------------------- |
| `ANANTHA_URL`        | `http://localhost:4000`       | Anantha instance URL         |
| `ANANTHA_API_KEY`    | —                             | API key for Anantha          |
| `BASE_URL`          | `http://localhost:4000`       | Exchange rate base URL       |
| `ORG_ID`            | `nil`                         | Default org for queries      |
| `SERVICE_API_KEY`   | —                             | Service-level auth           |

---

## 8. TOOL REFERENCE

All tools are prefixed with `acs_*` when called by agents. These are defined in `acs/acstools/acs.yaml`.

### 8.1 Core Tools (Level 1)

| Tool                 | Description                                                                  | Key Params                                 |
| -------------------- | ---------------------------------------------------------------------------- | ------------------------------------------ |
| `create_work`        | Create a new task with warnings about similar tasks. Optionally lock files.  | agent_id, title, description?, file_paths? |
| `claim_work`         | Claim a task for an agent. Returns task + guidance packet.                   | agent_id, task_id, scope_path?             |
| `release_work`       | Release a task lock. Returns structured feedback prompt.                     | agent_id, task_id                          |
| `lock_file`          | Lock a single file before editing.                                           | agent_id, task_id, file_path               |
| `unlock_file`        | Unlock file(s). Provide file_path or task_id.                                | agent_id, file_path? or task_id?           |
| `get_present_status` | See all agents' current status. Filter by sleeping agents.                   | agent_id?, status_filter?                  |
| `get_locked_files`   | See all currently locked files across all agents.                            | (none)                                     |
| `list_tasks`         | List tasks, optionally filtered by status.                                   | agent_id, status_filter?                   |
| `help`               | Comprehensive MCP tool reference with categories, levels, descriptions.      | category?, level?                          |
| `sleep`              | Put agent to sleep (long-poll) until a task arrives.                         | agent_id, timeout?                         |
| `wake`               | Manually wake a sleeping agent.                                              | agent_id                                   |

### 8.2 Knowledge Tools (Level 1)

| Tool                      | Description                                                                   | Key Params                                              |
| ------------------------- | ----------------------------------------------------------------------------- | ------------------------------------------------------- |
| `save_memory`             | Create a proposed memory entry (eternal truth).                                | kind, title, content, scope_path, tags?, triggers?      |
| `query_memories`          | Unified query: hybrid search if `query` provided, else list with filters.     | query?, scope_path?, kind?, status?, limit?, mode?      |
| `generate_guidance_packet`| Get structured guidance for a scope. Returns axioms, warnings, patterns.       | scope_path?, task_id?                                   |
| `set_memory_status`       | Update memory status: approved/rejected/stale.                                 | memory_id, status, notes?                               |

### 8.3 Cognition Tools (Level 1-2)

| Tool                          | Level | Description                                                  | Key Params                      |
| ----------------------------- | ----- | ------------------------------------------------------------ | ------------------------------- |
| `cognition_get`               | 1     | Get full spec for a module.                                  | app, path                       |
| `cognition_search`            | 1     | Full-text search across all spec entries.                    | query, status?, app?            |
| `cognition_list`              | 1     | List all specs, optionally filtered.                         | app?, status?                   |
| `cognition_list_undocumented` | 1     | Scan modules for missing specs.                              | app?                            |
| `cognition_propose`           | 2     | Propose a new/updated spec.                                  | app, path, title?, purpose?     |
| `cognition_approve`           | 2     | Approve a proposed spec.                                     | app, path, reviewer             |
| `cognition_reject`            | 2     | Soft-reject a proposed spec (back to under_review).          | app, path, reason?              |

### 8.4 Diagnostic Tools (Level 1)

| Tool                      | Description                                                            | Key Params                      |
| ------------------------- | ---------------------------------------------------------------------- | ------------------------------- |
| `config_lookup`           | Look up opencode/ACS configuration settings.                           | path?, key?                     |
| `connection_diagnostic`   | Check if external services are reachable (ACS, DB, LLM).               | service?, verbose?              |
| `query_memories`          | Unified query: hybrid search if `query` provided, else list with filters. | query?, scope_path?, kind?, status?, limit?, mode? |
| `memory_health_check`     | Check health of the Anantha memory system.                             | org_id?                         |
| `get_logs`                | Retrieve application logs with filtering.                              | level?, component?, search?     |

### 8.5 Error Trace Tools (Level 3)

| Tool                          | Description                                            | Key Params                |
| ----------------------------- | ------------------------------------------------------ | ------------------------- |
| `list_error_traces`           | List persistent error traces with filters.              | status?, service?, limit? |
| `ack_error_trace`             | Acknowledge an error trace (being investigated).        | trace_id                  |
| `resolve_error_trace`         | Mark an error trace as resolved.                       | trace_id                  |
| `create_task_from_error_trace`| Create an investigation task from an error trace.      | trace_id, agent_id?       |

### 8.6 Advanced Tools (Level 3, Admin)

| Tool            | Description                                                        | Key Params                              |
| --------------- | ------------------------------------------------------------------ | --------------------------------------- |
| `write_tool`    | Write a new YAML tool definition and hot-reload.                   | name, description, inputSchema, ...     |
| `refresh_tools` | Force reload all YAML tool definitions without restart.            | (none)                                  |
| `list_orgs`     | List all organizations in the system.                              | (none)                                  |
| `list_tools`    | List tools by category and level.                                  | category?, level?                       |
| `list_categories`| List all tool categories.                                         | (none)                                  |
| `time`          | Get or set ACS time offset (for testing).                          | action, seconds?                        |
| `exec_command`  | Execute shell commands (restricted to allowed list).               | command, args?, cwd?, timeout?          |


---

## 9. AGENT USAGE GUIDE

### 9.1 Standard Workflow

Every agent that works with Steward ACS follows this lifecycle:

```
1. REGISTER
   agent_id = "MyAgent"  — self-identify
   acs_get_present_status()  — check who's working

2. PREPARE (optional, recommended)
   generate_guidance_packet(scope_path: "my/area")
   query_memories(query: "what I'm working on")

3. CREATE + CLAIM
   acs_create_work(agent_id: "MyAgent", title: "Implement X")
   → returns task_id
   acs_claim_work(agent_id: "MyAgent", task_id: "...")
   → returns task + guidance packet

4. LOCK FILES
   acs_lock_file(agent_id: "MyAgent", task_id: "...", file_path: "lib/foo.ex")
   acs_lock_file(agent_id: "MyAgent", task_id: "...", file_path: "lib/bar.ex")

5. DO THE WORK
   — agent writes code, runs tests, researches —

6. SAVE LEARNINGS (before release!)
   acs_save_memory(kind: "learning", title: "Pattern: ...", 
                    content: "...", scope_path: "my/area")

7. RELEASE
   acs_release_work(agent_id: "MyAgent", task_id: "...")
   → returns feedback prompt

8. FEEDBACK (creates durable learnings)
   acs_submit_task_feedback(
     task_id: "...", 
     agent_id: "MyAgent",
     learned_for_agents: "What I discovered..."
   )
```

### 9.2 File Locking Protocol

```
BEFORE editing: acs_lock_file(agent_id, task_id, file_path)
BEFORE starting: acs_get_locked_files()  — check for conflicts
AFTER done:      acs_unlock_file(agent_id, file_path: file_path)
                  or: acs_unlock_file(agent_id, task_id: task_id)
```

- Lock before every edit. Unlock when done.
- 10-minute auto-release if agent goes silent.
- Call `acs_get_present_status()` to see what other agents are doing.

### 9.3 Knowledge Memory Protocol

```
BEFORE starting: generate_guidance_packet(scope_path: "...")
                  query_memories(query: "...")
DURING work:     save_memory(kind: "learning", title: "...", ...)
AFTER done:      acs_submit_task_feedback(learned_for_agents: "...")
```

Memory kinds: observation, learning, warning, pattern, bug, decision, invariant, axiom

### 9.4 Error Response Protocol

```
When you encounter an error:
1. Try to resolve it
2. If persistent:
   acs_list_error_traces()  — check if known
   acs_ack_error_trace(trace_id)  — mark as investigating
3. Fix it
4. acs_resolve_error_trace(trace_id)  — mark as resolved
```

---

## 10. INTEGRATION GUIDE

### 10.1 Integrating Steward ACS into a Project

1. **Run Steward ACS** as a standalone service (Docker or source)
2. **Configure your agent system** (opencode config) to connect to `http://<host>:4001/mcp`
3. **Set up auth** — API key (`MCP_API_KEY` / `acs_dev_...`) for Claude Code and plugins; **Auth0 OAuth** (`OAUTH_BEARER_ENABLED=true`) for Claude web Connectors (see `.env.remote`)
4. **Agents start using `acs_*` tools** — no SDK needed, tools are HTTP-callable

### 10.2 Adding Custom Tools

Tools are defined in YAML files. Create `{app}.yaml` and hot-reload:

```yaml
app: my_app
tools:
  - name: my_tool
    description: "Description of my tool"
    handler: ""
    endpoint: "http://my-service:8080/api/my-tool"
    category: custom
    level: 1
    inputSchema:
      type: object
      properties:
        param1:
          type: string
          description: "..."
```

Then call `acs_refresh_tools()` to load without restart.

### 10.3 Integrating with Anantha (Optional)

Steward ACS can query Anantha's memory system. Configure:

```bash
ANANTHA_URL=http://anantha:4000
ANANTHA_API_KEY=your-key
```

This enables `memory_health_check` and Anantha-memory-bridged tools.

---

## 11. TROUBLESHOOTING

| Symptom                                    | Likely Cause                        | Fix                                                     |
| ------------------------------------------ | ----------------------------------- | ------------------------------------------------------- |
| MCP connection rejected                    | Auth mismatch                       | Set `MCP_API_KEY` or enable `MCP_AUTH_LOCAL_FALLBACK`   |
| Database connection errors                 | PostgreSQL not running / wrong URL   | Check `DATABASE_URL`, verify PG is up                   |
| Tasks not auto-releasing                   | Sweeper not started / clock skew     | Check `AUDITOR_INTERVAL`, verify system time            |
| ETS cache stale after restart              | In-memory cache (cold start)         | Warm up with a few task operations                      |
| Memory search returns nothing              | No embedding provider configured     | Set `OLLAMA_URL` or `MIMO_API_KEY`                       |
| Container exits immediately                | `SECRET_KEY_BASE` missing            | Generate and set in `.env`                               |
| MCP tools not loading                      | Wrong tool path in config            | Check `ACS_TOOLS_PATH` / `ANANTHA_TOOLS_PATH`             |
| `eciting mcp_get_initial_connection`        | MCP protocol mismatch                | Verify agent MCP client version matches server           |

---

## 12. FAQ

**Q: What's the difference between Steward ACS and Anantha?**
A: Anantha is the parent product (intelligence/routing). Steward ACS is the coordination layer — it manages agent tasks, files, memory, and tools. They are separate applications. Steward ACS can run independently.

**Q: Do agents need an SDK to use Steward ACS?**
A: No. All tools are exposed as MCP (Model Context Protocol) HTTP endpoints. Any agent that can make HTTP POST requests can call `acs_*` tools.

**Q: Can Steward ACS run without a database?**
A: No. It needs SQLite3 (dev) or PostgreSQL (prod) for persistence — tasks, locks, memory, errors, logs all persist.

**Q: How many agents can Steward ACS handle?**
A: No hard limit. Performance depends on database throughput and ETS cache size. Single-node, single-postgres deployment handles hundreds of concurrent agents.

**Q: Is Steward ACS production-ready?**
A: Version 0.1.0 — actively developed. Core features (tasks, locks, memory, MCP) are stable. High availability, distributed multi-node, and alert routing are not yet implemented.

**Q: Can I rename the `acs_*` tool prefix?**
A: The prefix is defined in the YAML tool definitions (`acs/acstools/acs.yaml`). You can change it by editing the tool names there and in all agent prompts that reference them.

**Q: Can I run multiple instances?**
A: Yes — use different `ACS_CLUSTER_NAME` values to isolate namespaces. Each instance needs its own database.

**Q: Is there a web UI for humans?**
A: There's a minimal LiveView dashboard at port 4001 for development monitoring. It's agent-first — the primary interface is the MCP tool API.

---

## 13. KEY CONCEPTS GLOSSARY

| Concept              | Description                                                                 |
| -------------------- | --------------------------------------------------------------------------- |
| **Task**             | A unit of work an agent claims. Has status (todo/in_progress/done), locked_by_agent, auto_release timer, associated file paths. |
| **File Lock**        | Prevents multiple agents from editing the same file simultaneously. Unique per file path. 10-minute auto-release. |
| **Agent Status**     | Tracks what each agent is working on — current_task_id, purpose, application, component. |
| **Memory**           | A persistent "eternal truth" — knowledge, pattern, decision, or warning that outlives any single agent session. |
| **Guidance Packet**  | Curated bundle of relevant memories injected when an agent claims a task. Saves agents from searching for context. |
| **Cognition Spec**   | Structured documentation for a module: purpose, invariants, workflows, failure modes, constraints, tags. |
| **Error Trace**      | Persistent record of a runtime error — includes count, first/last seen, service, component. |
| **Cluster**          | A namespace that scopes all Steward ACS operations. Use separate clusters for dev/staging/prod. |
| **MCP Tool**         | An agent-callable function exposed via the MCP Gateway. Defined in YAML, hot-reloadable. |
| **ETS Cache**        | Erlang Term Storage — in-memory key-value store used for fast lookups of tasks, locks, and agent status. |
| **Scope Path**       | A namespace string for organizing memories and guidance (e.g., `auth/login`, `database/migrations`). |
| **Sweeper**          | Background process that releases stale tasks and locks after 10 minutes of inactivity. |

---

## 14. PROJECT STRUCTURE

```
anantha-os/
├── apps/steward_acs/           # Main application
│   ├── config/                 # Environment configs (dev, prod, test, runtime)
│   ├── lib/acs/                # Core modules (Task, Lock, Memory, MCP, Cognition)
│   ├── lib/acs_web/            # Phoenix web layer (Endpoint, LiveViews)
│   ├── lib/mix/tasks/          # Mix tasks (setup, cognition scan, reporting)
│   ├── priv/                   # Migrations, static assets, memory YAML
│   ├── test/                   # Tests
│   └── mix.exs                 # App definition
├── acs/acstools/               # YAML tool definitions
│   └── acs.yaml                # All acs_* tool definitions (861 lines)
├── docker-compose.steward_acs.yml
├── Dockerfile.steward_acs
├── AGENTS.md                   # Agent coordination rules (references Steward ACS)
├── .opencode/
│   ├── skills/steward-deployment/  # Deployment skill
│   ├── skills/acs-*/               # ACS-related skills
│   ├── guides/                    # Workflow, memory, cognition guides
│   └── agents/                    # Agent configurations
└── www/                          # Website (Astro-ready content here)
```

---

## 15. COMPETITIVE LANDSCAPE

| System              | Domain                              | How Steward ACS Differs                                          |
| ------------------- | ----------------------------------- | ---------------------------------------------------------------- |
| **Apache Curator**  | ZooKeeper client, coordination      | Curator focuses on distributed consensus. Steward ACS focuses on AI agent task/lifecycle. |
| **Netflix Conductor** | Workflow orchestration            | Conductor is DAG-based workflows. Steward ACS is agent-initiated claims — no DAGs. |
| **Temporal**        | Workflow engine                     | Temporal has retries, rollbacks, cron. Steward ACS is simpler — create/claim/release. |
| **LangGraph**       | Agent graph orchestration           | LangGraph orchestrates LLM calls. Steward ACS orchestrates files and knowledge across agents. |
| **CrewAI**          | Multi-agent framework               | CrewAI defines agent roles and tasks in Python. Steward ACS is infrastructure-layer, language-agnostic. |
| **MCP (protocol)**  | Model Context Protocol              | Steward ACS IS an MCP server — it implements the protocol.       |

---

> **Prepared for**: Astro website build
> **Date**: 2026-06-24
> **Content scope**: Full capabilities, limitations, architecture, configuration, tools, agent workflow, integration, troubleshooting
