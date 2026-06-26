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

### Docker (fastest)

```bash
git clone https://github.com/NaharEmet/steward_acs.git
cd steward_acs

echo "SECRET_KEY_BASE=$(mix phx.gen.secret)" >> .env
echo "DATABASE_URL=ecto://postgres:postgres@localhost:5432/acs" >> .env

docker compose -f docker-compose.example.yml up -d

curl http://localhost:4001/health
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

## Key Configuration

| Variable | Required | Default | Description |
|---|---|---|---|
| `SECRET_KEY_BASE` | Yes | — | Phoenix session signing secret (`mix phx.gen.secret`) |
| `DATABASE_URL` | Yes | — | PostgreSQL connection string (prod) |
| `ACS_CLUSTER_NAME` | No | `default` | Cluster namespace for multi-environment isolation |
| `ACS_DEVELOPER_NAME` | No | `unknown` | Developer identity for memory attribution |
| `AUDITOR_INTERVAL` | No | `30000` | Memory auditor polling interval (ms) |
| `MCP_API_KEY` | No | `dev-api-key` | MCP tool authentication |
| `OLLAMA_URL` | No | `http://localhost:11434` | Ollama endpoint for local embeddings |
| `ENABLED_LLM_PROVIDERS` | No | all | Comma-separated whitelist (e.g. `mimo,nim`) |

See `.env.example` and `config/runtime.exs` for the full reference.

---

## MCP Tool Overview

All tools are prefixed `acs_*` when called by agents.

| Category | Tools |
|---|---|
| **Core** | `create_work`, `claim_work`, `release_work`, `lock_file`, `unlock_file`, `get_present_status`, `list_tasks`, `sleep`, `wake`, `help` |
| **Knowledge** | `save_memory`, `search_memories`, `list_memories`, `set_memory_status`, `generate_guidance_packet` |
| **Cognition** | `cognition_get`, `cognition_search`, `cognition_propose`, `cognition_approve`, `cognition_reject`, `cognition_list`, `cognition_list_undocumented` |
| **Diagnostic** | `config_lookup`, `connection_diagnostic`, `find_similar_code`, `memory_health_check`, `get_logs` |
| **Error** | `list_error_traces`, `ack_error_trace`, `resolve_error_trace`, `create_task_from_error_trace` |
| **Advanced** | `write_tool`, `refresh_tools`, `time`, `list_orgs`, `list_categories`, `list_tools`, `exec_command`, `read_file`, `write_file`, `read_dir` |

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
├── docker-compose.example.yml
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
