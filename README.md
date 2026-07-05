# Steward ACS — Agent Coordination System

> Air traffic control for AI agents. Task lifecycles, file locking, knowledge memory, and MCP tools — all in a standalone Phoenix app.

Steward ACS is an **infrastructure layer** for multi-agent coordination. It runs as a standalone Phoenix web application (port 4001) and exposes MCP (Model Context Protocol) tools that any AI agent — Claude, GPT, Llama, or any MCP-compatible client — can call directly. It does not do the work itself; it manages the agents who do.

---

## Features

| Capability | Description |
|---|---|
| **Task Lifecycle** | Create, claim, release work units. 10-minute auto-release prevents stuck tasks. Similar-task detection prevents duplicate work. |
| **File Locking** | Lock files before editing. Prevents multi-agent edit conflicts. Auto-releases with task lifecycle. |
| **Knowledge Memory** | Persistent "eternal truths" — patterns, decisions, warnings shared across all agents. LLM-powered semantic search. |
| **MCP Tool Gateway** | Expose any REST API as an agent-callable MCP tool. YAML-defined, hot-reloadable, no server restart. |
| **Agent Presence** | Real-time tracking of every agent's current task, purpose, application, and component. |
| **Cognition Specs** | Structured module documentation — purpose, invariants, workflows, failure modes. Auto-generated guidance packets. |
| **Error Tracking** | Persistent error traces with acknowledgment and resolution workflow. Create investigation tasks from errors. |
| **Cluster Coordination** | Multi-cluster support with isolated namespaces per environment or team. |

---

## Quick Start

### Docker — Local

```bash
git clone https://github.com/NaharEmet/steward_acs.git
cd steward_acs

# Optional: configure LLM providers, dashboard credentials, etc.
# Copy and edit the example env file before starting:
# cp .env.example .env
# nano .env

docker compose up -d

curl http://localhost:4001/mcp/health

# Open http://localhost:4001 in your browser
# Dashboard login: admin / admin (configurable via ACS_USERNAME / ACS_PASSWORD)
```

> **Note:** Memory auditing and semantic search need at least one LLM provider API key. Set `NIM_API_KEY`, `MIMO_API_KEY`, `MINIMAX_API_KEY`, or `OPENAI_API_KEY` in `.env` (or directly in `docker-compose.yml`) to enable them. Without these, you'll see `Audit failed: :no_providers_enabled` in the logs.

### Docker — Remote

```bash
cp .env.remote .env
# Edit .env with your domain, secrets, and DB password
nano .env

docker compose -f docker-compose.remote.yml up -d

curl https://your-domain.com/mcp/health
```

### From Source

```bash
# Prerequisites: Elixir ~> 1.17, Erlang OTP 26+, SQLite3 or PostgreSQL
mix deps.get
mix ecto.setup
mix phx.server

# Run tests
mix test
```

---

## Architecture

```
                    ┌─────────────────────────────┐
                    │   AI Agents (MCP Clients)     │
                    │  Call acs_* tools via HTTP    │
                    └─────────────┬───────────────┘
                                  │
                    ┌─────────────▼───────────────┐
                    │     MCP Tool Gateway         │
                    │  YAML-defined, hot-reload    │
                    │  Routes to internal/external │
                    └─────────────┬───────────────┘
                                  │
                    ┌─────────────▼───────────────┐
                    │       Core Engine            │
                    │  Task Manager  Lock Manager  │
                    │  Memory Store  Presence      │
                    │  Cognition     Error Registry│
                    └─────────────┬───────────────┘
                                  │
                    ┌─────────────▼───────────────┐
                    │   ETS Cache (in-memory)      │
                    └─────────────┬───────────────┘
                                  │
                    ┌─────────────▼───────────────┐
                    │  PostgreSQL / SQLite          │
                    │  Tasks, locks, memory, logs  │
                    └─────────────────────────────┘
                    ┌─────────────────────────────┐
                    │  Background Processes        │
                    │  Sweeper  Auditor  MetaHarness│
                    └─────────────────────────────┘
```

**Tech stack:** Elixir 1.17+, Phoenix 1.8, Bandit 1.5 (HTTP), Ecto SQL 3.13, PostgreSQL (prod) / SQLite3 (dev), ETS caching, Phoenix PubSub, Tailwind CSS.

---

## Deployment

Two docker-compose configurations are provided for local and remote deployment:

| Config | File | Port | Database | TLS |
|--------|------|------|----------|-----|
| **Local** | `docker-compose.yml` | 4001 | SQLite (embedded) | None |
| **Remote** | `docker-compose.remote.yml` | 443 | PostgreSQL (container) | Auto (Caddy + Let's Encrypt) |

### Local

```bash
docker compose up -d
```

Builds from the Dockerfile, runs with MIX_ENV=dev on port 4001 with SQLite.

### Remote

```bash
cp .env.remote .env
# Fill in required values (see .env.remote for the full list):
#   DOMAIN, SECRET_KEY_BASE, MCP_API_KEY, SERVICE_API_KEY,
#   DB_PASSWORD, ACS_PASSWORD
docker compose -f docker-compose.remote.yml up -d --build
```

Deploys with:
- **Caddy** reverse proxy — auto TLS via Let's Encrypt (only public ports 80/443)
- **PostgreSQL** database — persistent, health-checked
- **Steward ACS** — production release on internal port 4001
- **Startup checks** — fails fast if default passwords or missing secrets
- **Auto-migrate** — runs `Acs.Release.migrate` before boot

### Manual TLS (without docker-compose.remote.yml)

#### Caddy

```caddyfile
steward.example.com {
    reverse_proxy localhost:4001
}
```

#### nginx

```nginx
server {
    listen 443 ssl;
    server_name steward.example.com;

    ssl_certificate     /etc/letsencrypt/live/steward.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/steward.example.com/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers on;

    proxy_set_header Connection '';
    proxy_http_version 1.1;
    proxy_buffering off;
    proxy_cache off;
    chunked_transfer_encoding on;

    location / {
        proxy_pass http://127.0.0.1:4001;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}

server {
    listen 80;
    server_name steward.example.com;
    return 301 https://$server_name$request_uri;
}
```

**Important for SSE:** The `/mcp/sse` endpoint uses Server-Sent Events (long-lived streaming connections). Ensure your reverse proxy does not buffer or timeout these connections. For nginx, `proxy_buffering off` and `proxy_http_version 1.1` are required. For Caddy, it works out of the box.

### Obsidian Vault Sync

Steward ACS can read and write memories directly from an Obsidian vault. Memories are stored as `.md` files with YAML frontmatter — editable in Obsidian, readable by Steward.

#### Workflow: Syncthing

Your local Obsidian vault syncs to the server via Syncthing. Steward reads the synced files.

1. On your local machine, install [Syncthing](https://syncthing.net/)
2. Deploy `docker-compose.remote.yml` with the Syncthing service uncommented
3. Open `http://your-server:8384` and connect your local Syncthing to it
4. Share your Obsidian vault folder to the server's `obsidian_vault` volume
5. Set these env vars on the server:

```
MEMORY_STORE=obsidian
OBSIDIAN_VAULT_PATH=/obsidian
```

#### Config

```bash
# Local dev (orchestrate externally)
export MEMORY_STORE=obsidian
export OBSIDIAN_VAULT_PATH=/path/to/your/vault
```

In Docker, uncomment the `obsidian_vault` volume and `syncthing` service in your compose file. The file watcher debounces events (1000ms) and excludes `.obsidian/` internal files.

---

## Key Configuration

| Variable | Required (prod) | Default | Description |
|---|---|---|---|
| `SECRET_KEY_BASE` | Yes | — | Phoenix secret (`mix phx.gen.secret`) |
| `DATABASE_URL` | Yes | — | PostgreSQL connection string |
| `MCP_API_KEY` | Yes | — | MCP tool authentication |
| `SERVICE_API_KEY` | Yes | — | Internal service MCP key |
| `ACS_PASSWORD` | Yes | `admin` | Dashboard password (must change in prod) |
| `ACS_USERNAME` | No | `admin` | Dashboard username |
| `PHX_HOST` / `DOMAIN` | Yes | — | Public hostname for URLs and LiveView origin checks |
| `ACS_CLUSTER_NAME` | No | `default` | Cluster namespace |
| `ACS_DEVELOPER_NAME` | No | `unknown` | Developer identity for memory attribution |
| `COOKIE_SIGNING_SALT` | No | derived | Session cookie salt (set at Docker build for stable LiveView auth) |
| `CORS_ORIGINS` | No | `*` | Comma-separated browser origins allowed for MCP CORS |
| `AUDITOR_INTERVAL` | No | `30000` | Memory auditor polling interval (ms) |
| `OLLAMA_URL` | No | `http://localhost:11434` | Ollama endpoint for local embeddings |
| `MEMORY_STORE` | No | `yaml` | Storage format: `yaml` or `obsidian` |
| `OBSIDIAN_VAULT_PATH` | No | — | Filesystem path to Obsidian vault |
| `ENABLED_LLM_PROVIDERS` | No | all | Comma-separated whitelist (e.g. `mimo,nim`) |
| `NIM_API_KEY` | No | — | NVIDIA NIM API key for LLM evaluation |
| `MIMO_API_KEY` | No | — | Mimo API key for LLM evaluation |
| `MINIMAX_API_KEY` | No | — | MiniMax API key for LLM evaluation |
| `OPENAI_API_KEY` | No | — | OpenAI API key for LLM evaluation |
| `OPENAI_BASE_URL` | No | — | Custom OpenAI-compatible endpoint URL |
| `OPENAI_MODEL` | No | — | OpenAI model name override |
| `MCP_TOOLS_PATH` | No | `<app>/acs/acstools` | Comma-separated directories for YAML tool definitions |
| `MCP_AUTH_LOCAL_FALLBACK` | No | `false` | Allow unauthenticated MCP calls from localhost |
| `HTTP_SLEEP_MAX_MS` | No | — | Max sleep duration for `sleep` tool (ms) |

| `ALLOWED_COMMANDS` | No | — | Comma-separated allowed commands for `exec_command` tool |
| `BRIDGE_ALLOWED_HOSTS` | No | — | Comma-separated allowed hosts for the HTTP Bridge |
| `ACS_ADMIN_EMAILS` | No | — | Comma-separated admin emails for notifications |
| `LOG_INGEST_KEY` | No | — | Shared key for log ingestion endpoint |
| `OAUTH_BEARER_ENABLED` | No | `false` | Enable Auth0 JWT validation for Claude Connectors |
| `AUTH0_DOMAIN` | When OAuth on | — | Auth0 tenant domain (e.g. `dev-jw5wgp2b.us.auth0.com`) |
| `AUTH0_AUDIENCE` | When OAuth on | — | MCP API identifier — must match Claude connector URL (e.g. `https://prod.stewardacs.xyz/mcp/sse`) |
| `AUTH0_ISSUER` | No | `https://${AUTH0_DOMAIN}/` | Override OIDC issuer if non-standard |
| `MCP_PUBLIC_URL` | When OAuth on | — | Public base URL for OAuth metadata (e.g. `https://prod.stewardacs.xyz`) |
| `MCP_RESOURCE_URL` | No | same as audience | Resource URL in protected-resource metadata |
| `MCP_QUERY_KEY_AUTH` | No | `false` | Allow `?api_key=` on MCP SSE (legacy connector fallback) |
| `SESSION_VALIDITY_DAYS` | No | `7` | Dashboard session lifetime |

### LLM Provider Setup

Memory auditing and semantic search need an LLM provider. Set at least one of these:

| Variable | Provider |
|---|---|
| `NIM_API_KEY` | NVIDIA NIM |
| `MIMO_API_KEY` | Mimo |
| `MINIMAX_API_KEY` | MiniMax |
| `OPENAI_API_KEY` | OpenAI (also set `OPENAI_BASE_URL` / `OPENAI_MODEL` for custom endpoints) |

You can restrict which providers are used via `ENABLED_LLM_PROVIDERS` (comma-separated, e.g. `mimo,nim`). By default all enabled providers with valid API keys are tried in priority order.

### MCP Tool Definitions

Steward ACS discovers tool definitions from YAML files on disk. The search path is configured via:

- `MCP_TOOLS_PATH` env var (comma-separated directories)
- `config :steward_acs, Acs.MCP.ToolLoader, tools_paths:` in config files
- Default: `<app_dir>/acs/acstools/`

Create tool YAML files in one of these directories and they'll be hot-reloaded automatically. See `priv/acs_tools/` for examples.

See `.env.remote`, `.env.example`, and `config/runtime.exs` for the full reference.

---

## MCP Tool Overview

All tools are prefixed `acs_*` when called by agents.

| Category | Tools |
|---|---|
| **Core** | `create_work`, `claim_work`, `release_work`, `lock_file`, `unlock_file`, `get_present_status`, `list_tasks`, `sleep`, `wake`, `help` |
| **Knowledge** | `save_memory`, `query_memories`, `set_memory_status`, `generate_guidance_packet` |
| **Cognition** | `cognition_get`, `cognition_search`, `cognition_propose`, `cognition_approve`, `cognition_reject`, `cognition_list`, `cognition_list_undocumented` |
| **Diagnostic** | `config_lookup`, `connection_diagnostic`, `query_memories`, `memory_health_check`, `get_logs` |
| **Error** | `list_error_traces`, `ack_error_trace`, `resolve_error_trace`, `create_task_from_error_trace` |
| **Advanced** | `write_tool`, `refresh_tools`, `time`, `list_orgs`, `list_categories`, `list_tools`, `exec_command` |

---

## Project Structure

```
steward_acs/
├── config/            # Environment configs (dev, prod, test, runtime)
├── lib/
│   ├── acs.ex         # Public API module
│   ├── acs/           # Core logic: tasks, locks, memory, MCP, cognition
│   ├── acs_web/       # Phoenix web layer + LiveView dashboard
│   └── mix/tasks/     # Mix tasks (keys, cognition, meta-harness)
├── priv/
│   ├── acs_memory/    # Canonical YAML memory files
│   └── repo/migrations/
├── site/              # Marketing landing page (HTML/CSS/JS)
├── test/
├── assets/
├── Dockerfile
├── docker-compose.yml          # Local dev (SQLite, port 4001)
├── docker-compose.remote.yml   # Remote prod (PostgreSQL, Caddy TLS)
├── Caddyfile                   # TLS config for remote
├── .env.remote                 # Remote env var template
└── mix.exs
```

---

## Development

```bash
# Setup
mix setup

# Run dev server (port 4001)
mix phx.server

# Interactive shell
iex -S mix phx.server

# Run tests
mix test

# Lint
mix credo
```

---

## License

Apache License 2.0
