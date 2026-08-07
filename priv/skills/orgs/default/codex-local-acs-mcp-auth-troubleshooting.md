---
description: "Diagnose Codex startup failures when the local Steward ACS MCP endpoint rejects or cannot receive API-key authenticated requests."
name: "codex-local-acs-mcp-auth-troubleshooting"
proposed_by: "nahar emet"
scope_paths: ["guides/deployment-testing", "lib/acs/mcp"]
status: "approved"
tags: ["codex", "mcp", "acs", "authentication", "local-development"]
when_to_use: "Use when Codex reports ACS MCP HTTP 401 errors or cannot connect to localhost:4001."
audit_reasoning: "The skill is highly actionable, complete, and well-structured. It provides clear, numbered steps with exact commands, file paths, and verification checks. The description is distinct and informative. The audience (coding) is appropriate for the CLI and shell commands used. It covers prerequisites, steps, verification, and failure recovery, making it a robust troubleshooting guide. No duplicates exist in the provided skills."
audit_score: 10
audit_status: "ok"
audited_at: "2026-08-07T07:45:14.980076Z"
approved_at: "2026-08-07T07:45:14.988695Z"
approved_by: "llm"
reviewed_at: "2026-08-07T07:45:14.988695Z"
reviewed_by: "llm"
---

## Prerequisites

- Steward ACS repository on `dev`.
- Codex CLI installed.
- Local ACS configuration available in `.env` and `~/.codex/config.toml`.

## Steps

1. Confirm the ACS MCP URL in Codex is the local endpoint:
   ```bash
   codex mcp list
   ```
   It should show `http://localhost:4001/mcp/v1/messages`.

2. Check the local service without revealing secrets:
   ```bash
   curl -fsS http://127.0.0.1:4001/mcp/health
   ```
   If connection is refused, start the local stack with the project’s documented command, such as `docker compose up -d` or `mix phx.server`.

3. Compare the configured key without printing either value:
   ```bash
   cfg_key=$(sed -n 's/^"x-api-key" = "\(.*\)"$/\1/p' ~/.codex/config.toml)
   env_key=$(awk -F= '/^[[:space:]]*MCP_API_KEY=/ {v=$2; gsub(/^"|"$/, "", v); print v; exit}' .env)
   test -n "$cfg_key" && test "$cfg_key" = "$env_key" && echo match=yes || echo match=no
   ```

4. For local ACS, put the same `MCP_API_KEY` in Codex’s `x-api-key` header. Do not use `codex mcp auth` for this API-key server; that command is for servers using their own supported auth flow, such as OAuth.

5. After changing the key or starting the server, restart Codex so it reloads `~/.codex/config.toml`, then rerun `codex mcp list` and the health check.

## Verification

- `curl -fsS http://127.0.0.1:4001/mcp/health` succeeds.
- `codex mcp list` shows ACS enabled.
- A fresh Codex session initializes ACS without HTTP 401.

## Failure recovery

- If health is refused, inspect `docker ps` and server logs; the MCP client cannot authenticate a service that is not running.
- If health succeeds but initialization returns 401, compare the key again and verify the server was restarted after changing `.env`.
- Do not paste API-key values into chat, logs, commits, or screenshots.
