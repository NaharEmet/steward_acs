# Steward ACS — Agent Coordination System

[![Hex.pm](https://img.shields.io/hexpm/v/steward_acs)](https://hex.pm/packages/steward_acs)

**Steward ACS** is a coordination system for AI agents. It manages tasks, file locking, memory, and tools — allowing multiple agents to collaborate without stepping on each other.

> Formerly known as "Agent Coordination System (ACS)".

---

## Features

- **Task Management**: Create, claim, and release work units
- **File Locking**: Prevent concurrent editing conflicts
- **Knowledge Memory**: Save and retrieve learnings across sessions
- **Cognition Specs**: Document module purpose, invariants, and failure modes
- **MCP Tools**: Full tool gateway for AI agent interaction
- **CRM Integration**: Sync contacts, companies, deals from CRM providers

---

## Quick Start

```bash
# Add to your mix.exs
{:steward_acs, "~> 0.1"}

# Configure
config :steward_acs, :allowed_paths, ["/tmp", "/var/data"]

# Start
mix setup
mix phx.server
```

---

## Tool Reference

### Agent Coordination

| Tool | Description | Params |
|------|-------------|--------|
| `create_work` | Create a new task for an agent. | agent_id, title, description?, file_paths? |
| `claim_work` | Claim a task and get guidance packet. | agent_id, task_id, scope_path? |
| `release_work` | Release a task and get feedback prompt. | agent_id, task_id |
| `lock_file` | Lock a file before editing. | agent_id, task_id, file_path |
| `unlock_file` | Unlock a file after editing. | agent_id, file_path? or task_id? |
| `get_present_status` | See what all agents are working on. | agent_id? |
| `get_locked_files` | See all currently locked files. | (none) |
| `list_tasks` | List tasks by agent. | agent_id, status_filter? |
| `sleep` | Put agent to sleep until a task arrives. | agent_id, timeout? |

### Knowledge Memory

| Tool | Description | Params |
|------|-------------|--------|
| `save_memory` | Save an eternal truth as knowledge. | kind, title, content, scope_path |
| `search_memories` | Full-text search across memories. | query, scope?, kind?, limit? |
| `list_memories` | List memories with filters. | scope_path?, kind?, status?, limit? |
| `set_memory_status` | Update memory status. | memory_id, status, notes? |
| `generate_guidance_packet` | Get structured guidance for a scope. | scope_path? |

### Cognition Specs

| Tool | Description | Params |
|------|-------------|--------|
| `cognition_get` | Get a module's spec. | app, path |
| `cognition_search` | Search specs. | query, status?, app? |
| `cognition_propose` | Propose a new spec. | app, path, title?, purpose?, ... |
| `cognition_approve` | Approve a proposed spec. | app, path, reviewer |
| `cognition_reject` | Soft-reject a spec. | app, path, reason |
| `cognition_list` | List all specs. | app?, status? |
| `cognition_list_undocumented` | Find modules without specs. | app? |

### Diagnostic & Admin

| Tool | Description | Params |
|------|-------------|--------|
| `config_lookup` | Look up opencode configuration. | key?, path? |
| `connection_diagnostic` | Check service connectivity. | service?, verbose? |
| `find_similar_code` | Semantic code search. | query, limit?, scope? |
| `memory_health_check` | Check memory system health. | org_id? |
| `get_logs` | Retrieve application logs. | level?, component?, ... |
| `help` | List all MCP tools. | category?, level? |
| `time` | Get or set ACS time offset. | action, seconds? |
| `list_tools` | List tools by category and level. | category?, level? |
| `list_categories` | List all tool categories. | (none) |
| `list_orgs` | List all organizations. | (none) |
| `list_plugins` | List registered plugins. | (none) |
| `refresh_tools` | Force reload tool definitions. | (none) |

### Error Management

| Tool | Description | Params |
|------|-------------|--------|
| `list_error_traces` | Find persistent error patterns. | status?, service?, component?, min_count?, limit? |
| `ack_error_trace` | Acknowledge an error trace. | trace_id |
| `resolve_error_trace` | Mark an error trace as resolved. | trace_id |
| `create_task_from_error_trace` | Create task from an error. | trace_id, agent_id? |

### Cluster Filesystem

| Tool | Description | Params |
|------|-------------|--------|
| `read_file` | Read files from the cluster filesystem. | path |
| `write_file` | Write files to the cluster filesystem. | path, content |
| `read_dir` | List directory contents. | path |
| `write_tool` | Register custom tools dynamically. | name, description, inputSchema, ... |

---

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SECRET_KEY_BASE` | - | Phoenix secret key (required) |
| `DATABASE_URL` | - | PostgreSQL connection (required) |
| `ACS_HOST` | `localhost` | Server host |
| `ACS_PORT` | `4000` | Server port |
| `ALLOWED_PATHS` | `/tmp` | File access allowlist |

### Application Config

```elixir
config :steward_acs,
  allowed_paths: ["/tmp", "/var/data"]
```

---

## Development

```bash
git clone https://github.com/dot-prompt/steward-acs.git
cd steward-acs
mix setup
mix test
```

---

## Architecture

```
OpenCode Agent → MCP Gateway → Tool Dispatcher → Handlers
                         │
                    Knowledge Memory
                         │
                    PostgreSQL (State)
```

---

## License

MIT License — see [LICENSE](LICENSE).

---

## Resources

- [Hex.pm](https://hex.pm/packages/steward_acs)
- [GitHub](https://github.com/dot-prompt/steward-acs)
