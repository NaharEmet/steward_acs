---
audit_reasoning: All checks passed
audit_score: 10
audit_status: ok
audited_at: 2026-07-04T19:45:21.346841Z
description: ACS deployment styles: code development vs org memory
name: deployment
tags: ["deployment", "ops", "admin"]
---

# Deployment Styles

ACS supports two deployment styles depending on your use case.

## Code Development

Lightweight setup for individual developers coordinating with AI agents. Agents manage tasks, memories, and files on your local project.

| Aspect | Config |
|--------|--------|
| Compose file | `docker-compose.yml` |
| Database | SQLite (file-based, no extra container) |
| Memory store | YAML files in `priv/acs_memory/` |
| Auth | API key (`MCP_API_KEY`) + dashboard basic auth |
| Network | Localhost only, port 4001 |
| TLS | None |

```bash
docker compose up -d
```

Memories are machine-readable YAML — agents use them for context. No human-facing knowledge tooling.

## Org Memory

Production setup for organizational knowledge management. Memories live in an Obsidian vault that humans edit directly and sync via Syncthing.

| Aspect | Config |
|--------|--------|
| Compose file | `docker-compose.remote.yml` or `docker-compose.cloudflare.yml` |
| Database | PostgreSQL (`remote.yml`) or SQLite (`cloudflare.yml`) |
| Memory store | Obsidian vault (`MEMORY_STORE=obsidian`) |
| Auth | API key + optional Auth0 OAuth |
| OAuth users | See skill **auth0-users** — create Auth0 accounts for Claude Connectors |
| Network | Public domain with TLS (Caddy) |
| Sync | Syncthing — local Obsidian ↔ server vault |

Agents write memories as markdown files with YAML frontmatter. Humans open the same vault in Obsidian. Both see the same knowledge.

```bash
cp .env.remote .env
# Fill in: SECRET_KEY_BASE, MCP_API_KEY, DB_PASSWORD, ACS_PASSWORD
# Set MEMORY_STORE=obsidian, OBSIDIAN_VAULT_PATH=/obsidian
docker compose -f docker-compose.remote.yml up -d --build
```

## Which one to use

| You want... | Use |
|-------------|-----|
| Agent coordination on a dev project | Code Development |
| Persistent org knowledge, human-readable | Org Memory |
| Both at the same time | Run Code Development locally, Org Memory on a server. They're independent instances. |
