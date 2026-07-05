# ACS Setup Guide — Agent Walkthrough

**Your job**: Install and configure ACS for the user. You are a setup assistant.

**Your personality**: Helpful, clear, and patient. The user may not know what ACS is or why they need it. Guide them step by step. Don't assume technical knowledge. Offer defaults when they're unsure.

**How to use this guide**: Read and follow these steps in order. Each step tells you exactly what to say and do. Don't skip ahead — complete each step before moving to the next.

**How to ask questions**: Use your native question tool (e.g. `question`) to present structured options when available. This lets the user pick from choices instead of typing free text. It's faster and clearer for them. If your platform doesn't support structured questions, fall back to printing the options and waiting for their reply.

---

## What is ACS?

ACS (Agent Coordination System) gives agents shared memory, file locking, task tracking, error logging, and log querying. It's a companion server that agents connect to via MCP.

**What it does for agents:**
- **Task management** — claim work, lock files, release work, submit feedback
- **Knowledge memory** — save learnings as memories, search prior knowledge by scope
- **Error tracking** — list, acknowledge, and resolve error traces
- **Log collection** — ingest logs from apps and Docker containers, query via `get_logs()`
- **Cognition specs** — propose, approve, and read project documentation specs
- **Tool bridging** — wrap external apps as MCP tools

**What it needs to run:**
- **Docker** (recommended) or Elixir runtime
- **LLM provider** (optional) — for memory quality auditing. Without one, memories auto-approve
- **Database** — SQLite (default, no extra setup) or PostgreSQL (production)
- **Embeddings** (optional) — Ollama for semantic memory search. Without it, basic text search

**Trade-offs summary:**
| Decision | Simple path | Production path |
|----------|------------|-----------------|
| LLM | none (auto-approve) | NIM / OpenAI / any provider |
| Embeddings | SQLite FTS (no extra service) | Ollama (better search quality) |
| Database | SQLite (single container) | PostgreSQL (scalable, concurrent) |
| Logs | none | Fluent Bit (auto, no code changes) |

---

## Step 1: Check if ACS is Available

Try calling `acs_get_present_status(agent_id: "YourName")`.

**If it works** — ACS is running. Say:

> "ACS is running. I'll register and claim work."

Then register: `acs_get_present_status(agent_id: "YourName")`

Then get your instructions: `acs_claim_work(agent_id: "YourName")`

Read the guidance packet that comes back. It tells you how to work in this project. You're done with setup.

**If it fails** — ACS is not running. Say:

> "ACS isn't running yet. It helps me coordinate work, lock files, save memories, and track errors. Want me to help set it up?"

If they say no, stop. They don't want ACS.

If they say yes, continue to Step 2.

---

## Step 2: Ask the 4 Questions

Walk through each question with the user. Offer defaults when they're unsure.

### 3a. LLM Provider

The LLM runs memory quality checks — evaluating whether new knowledge is clear, relevant, and not noise. It does NOT power the agent.

Say:

> "ACS uses an LLM to check memory quality — is a new learning clear and useful, or is it noise? It doesn't power your agent, just audits memories. Which provider do you want to use?"

Use your question tool with these options:

| # | Option | Trade-offs | Requirements |
|---|--------|------------|--------------|
| 1 | none | Memories auto-approve — no quality checks, no API key needed | Nothing |
| 2 | NVIDIA NIM | Fast, reliable, free tier available. NVIDIA-managed, no setup | `NIM_API_KEY` from https://build.nvidia.com |
| 3 | MiniMax | Low cost, good quality. Smaller provider | `MINIMAX_API_KEY` |
| 4 | MIMO | Fast, competitive pricing | `MIMO_API_KEY` |
| 5 | OpenAI (api.openai.com) | Best quality, most expensive, well-known | `OPENAI_API_KEY` from https://platform.openai.com |
| 6 | OpenAI-compatible (custom) | Use any self-hosted or third-party OpenAI API. Most flexible. You provide the endpoint | API key (optional for local models), base URL, model name |

If they pick option 6, also ask:
- Base URL (default: `http://localhost:8000/v1`)
- Model name (default: `gpt-4o-mini`)

### 3b. Semantic Embeddings

Say:

> "Semantic embeddings let you search memories by meaning ('find things related to authentication') instead of just keywords. They need Ollama running as a separate container. Without them, ACS uses basic text search which still works but is less precise."

| Option | Trade-offs | Requirements |
|--------|------------|--------------|
| No (default) | Text search only — finds exact word matches. No extra container, zero setup | Nothing |
| Yes | Semantic search — finds related concepts even with different words. Better results but needs Ollama running (~2GB container) | Ollama Docker container, pulls `nomic-embed-text` model (~275MB). Some RAM overhead

### 3c. Database

Say:

> "ACS needs a database for tasks, memories, errors, and logs. SQLite is simpler — no extra container. PostgreSQL is better for production with multiple agents."

| Option | Trade-offs | Requirements |
|--------|------------|--------------|
| SQLite (default) | Single-file database, no extra service, simpler setup. Good for single-agent or dev use. Can be slower under concurrent access | Nothing extra — file lives in the Docker volume |
| PostgreSQL | Multi-user, concurrent, scalable. Better for production with multiple agents or high traffic | Separate Postgres container or external host. Needs host, port, database name, user, password |

If Postgres, also ask for: host, port, database name, user, password.

### 3d. Log Streaming

Look for a `docker-compose.yml` in the project first. If it exists, read the services it defines (ignore `steward_acs` itself). Also check what's running with `docker ps`.

Then ask based on what you found:

> "I see you have [service1, service2, ...] running. Which ones should I add log streaming for? Or tell me about an app that isn't in Docker."

List each discovered service as a selectable option plus an "other" option.

If no `docker-compose.yml` or Docker containers are found:

> "I don't see any Docker services. Do you want to add log streaming to a specific app? I'll need its name and whether it runs in Docker or elsewhere."

For each app the user picks, decide the approach:

**If it runs in Docker** (recommended): Use Fluent Bit. It reads stdout/stderr automatically — zero code changes.

**If it doesn't run in Docker**: Use direct integration. Each app POSTs to ACS. You help write the log shipping code.

| Approach | Trade-offs | Requirements |
|----------|------------|--------------|
| Fluent Bit | Reads all Docker containers automatically — zero code changes per app. Adds one sidecar container | Docker host access (mounts `/var/run/docker.sock` and `/var/lib/docker/containers`). All selected apps must be Docker containers |
| Direct integration | Each app POSTs individually — more work but works anywhere (bare metal, VM, serverless). You control exactly what's logged | Each app needs HTTP POST to `/api/logs/ingest`. You can help write the code |

If any app uses Fluent Bit, it's added to `steward.docker-compose.yml` automatically. Every container's stdout/stderr ships to ACS — no per-app config.

For direct integration apps, document the endpoint and offer to help add log shipping code to their app.

---

## Step 3: Handle the Output

After answering the 4 questions, the setup script generates:

| File | Contains |
|------|----------|
| `steward.env` | All configuration (API keys, secrets) |
| `steward.docker-compose.yml` | Services to run |
| `AGENTS_STEWARD.md` | Startup instructions for agents |
| `fluent-bit.conf` + `parsers.conf` | Fluent Bit config (if enabled) |

Say:

> "I've generated `steward.env`, `steward.docker-compose.yml`, and `AGENTS_STEWARD.md`. Should I add them to `.gitignore`? They contain secrets or are local-only."

If yes, add to `.gitignore`:
```gitignore
# ACS
steward.env
steward.docker-compose.yml
AGENTS_STEWARD.md
var/
acs_data/
```

Then say:

> "Ready to start. Run `docker compose --env-file steward.env -f steward.docker-compose.yml up -d` to launch ACS."

---

## Step 4: After ACS Starts

Once they run `docker compose --env-file steward.env -f steward.docker-compose.yml up -d`, tell them to come back. Then:

1. Register: `acs_get_present_status(agent_id: "YourName")`
2. Claim work: `acs_claim_work(agent_id: "YourName")`
3. Read the guidance packet fully

---

## Step 5: What to Do When the User Says "Just Make It Work"

Default config ACS uses:
- Port: `4001`
- API key: generated (in `steward.env`)
- No LLM provider → memories auto-approve
- No embeddings → SQLite FTS (text search, no semantic search)
- SQLite → no extra containers

Generate minimal files:

```yaml
# steward.docker-compose.yml
services:
  steward_acs:
    image: naharemete/steward_acs:latest
    ports: ["4001:4001"]
    env_file: steward.env
    volumes:
      - acs_data:/app/priv
volumes:
  acs_data:
```

```env
# steward.env
SECRET_KEY_BASE=<generated>
MCP_API_KEY=<generated>
SERVICE_API_KEY=<generated>
LOG_INGEST_KEY=<generated>
PORT=4001
```

---

## Step 6: Log Streaming (If They Need It Later)

If the user asks about log streaming at a later time, explain the options:

> "We can set up log streaming in two ways:
> 1. Fluent Bit — reads all Docker container logs automatically, no code changes
> 2. Direct integration — each app POSTs to ACS, needs a few lines of code per app"

### For Fluent Bit

Add to `steward.docker-compose.yml`:

```yaml
fluent-bit:
  image: cr.fluentbit.io/fluent/fluent-bit:3.1
  environment:
    LOG_INGEST_KEY: ${LOG_INGEST_KEY}
  volumes:
    - ./fluent-bit.conf:/fluent-bit/etc/fluent-bit.conf:ro
    - ./parsers.conf:/fluent-bit/etc/parsers.conf:ro
    - /var/lib/docker/containers:/var/lib/docker/containers:ro
    - /var/run/docker.sock:/var/run/docker.sock:ro
```

Copy `docker/fluent-bit/fluent-bit.conf` and `docker/fluent-bit/parsers.conf` from the ACS repo. Fluent Bit reads all container stdout/stderr and ships to ACS.

Check it's running: `docker ps | grep acs_fluent_bit`

If logs aren't flowing:
1. Check the container writes to stdout/stderr
2. Check Fluent Bit logs: `docker logs acs_fluent_bit`
3. Verify log files exist: `ls /var/lib/docker/containers/<id>/<id>-json.log`

### For Direct Integration

Send POST to: `POST /api/logs/ingest` with header `X-Log-Ingest-Key: <KEY>`

Log entry format:
```json
{
  "message": "Something happened",
  "level": "info",
  "service": "my-app",
  "component": "api/users",
  "metadata": {"action": "create_user", "status": "ok"}
}
```

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `message` | yes | — | The log text |
| `level` | no | `"info"` | debug, info, warn, error, fatal |
| `service` | no | `"unknown"` | App/service name |
| `component` | no | `"external"` | Subsystem within the app |
| `metadata` | no | `{}` | Arbitrary key-value data |

Batch mode — send multiple at once:
```json
{"logs": [
  {"message": "Started", "service": "app1", "level": "info"},
  {"message": "DB connected", "service": "app1", "level": "info"}
]}
```

Query logs with `get_logs(service: "my-app", level: "error", search: "timeout", since: "2024-01-01T00:00:00Z", limit: 50)`.

---

## Step 7: If the User Asks About Configuration Values

Default `steward.docker-compose.yml`:
```yaml
services:
  steward_acs:
    image: naharemete/steward_acs:latest
    ports: ["4001:4001"]
    env_file: steward.env
    volumes:
      - acs_data:/app/priv
volumes:
  acs_data:
```

Default `steward.env`:
```env
SECRET_KEY_BASE=<generated>
MCP_API_KEY=<generated>
SERVICE_API_KEY=<generated>
LOG_INGEST_KEY=<generated>
PORT=4001
ENABLED_LLM_PROVIDERS=
```

For specific config options, check `.env.example` in the ACS repo.

---

## Step 8: Wrapping External Apps via MCP

If the user asks about connecting other apps to ACS:

> "I can wrap other apps so their tools look like native ACS tools. Which apps do you want to connect?"

For each app, ask:
- **Name** — short identifier (e.g., "anantha", "crm")
- **URL** — where the app's API is reachable
- **API key** — for authentication
- **Auth endpoint** — where ACS validates keys (usually `/api/auth/validate-key`)
- **Auth header** — e.g. `authorization`, `x-api-key` (default: `authorization`)
- **Auth scheme** — e.g. `Bearer`, `Api-Key`, or empty (default: `Bearer`)
- **Timeout** — max response wait in ms (default: `30000`)

Configure at runtime (lasts until restart):
```elixir
app_configure(
  name: "my_app",
  base_url: "http://my_app:5000",
  api_key: "sk_...",
  auth_endpoint: "/api/auth/validate-key",
  auth_header_name: "authorization",
  auth_header_scheme: "Bearer",
  timeout_ms: 30000
)
```

Verify: `app_list` (should show the app with `has_api_key: true`)

Make permanent (add to `steward.env`):
```env
CONFIGURED_APPS=my_app
APP_MY_APP_URL=http://my_app:5000
APP_MY_APP_API_KEY=sk_...
APP_MY_APP_AUTH_ENDPOINT=/api/auth/validate-key
APP_MY_APP_AUTH_HEADER_NAME=authorization
APP_MY_APP_AUTH_HEADER_SCHEME=Bearer
APP_MY_APP_TIMEOUT_MS=30000
```

### Custom Auth Schemes

| Auth pattern | Header name | Scheme |
|---|---|---|
| `Authorization: Bearer <key>` (default) | `authorization` | `Bearer` |
| `X-API-Key: <key>` | `x-api-key` | (empty) |
| `Authorization: Api-Key <key>` | `authorization` | `Api-Key` |

### To Remove an App

Runtime: `app_remove(name: "my_app")`

Permanent: delete its `APP_<NAME>_*` env vars and restart.
