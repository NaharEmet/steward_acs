# Development Workflow — Steward (remote) vs Local (test-only)

## The rule

- **Remote (anantha) is where we work.** All memories, all ACS instructions, task coordination, and org knowledge live on `https://anantha.stewardacs.xyz` (server key `steward`, coding endpoint `/mcp/sse`, OAuth via Auth0).
- **Local is only for testing new code changes** you are working on (server key `acs`, `http://localhost:4001/mcp/v1/messages`, `x-api-key` auth). It is never the primary store.

## Why

- Steward's memory, specs, skills, and task state are shared across the team — everyone works against the same remote org (anantha).
- Local runs are isolated sandboxes used to exercise changes to the ACS codebase itself (`/lib/`, migrations, MCP server) before they ship.
- If you treat local as a second brain, memories and tasks fragment between two stores and nobody can trust either.

## Connecting

### Cursor

File: `.cursor/mcp.json` (gitignored — holds real keys).

```json
{
  "mcpServers": {
    "acs": {
      "type": "http",
      "url": "http://localhost:4001/mcp/v1/messages",
      "headers": { "x-api-key": "<local-acs-api-key>" }
    },
    "steward": {
      "type": "http",
      "url": "https://anantha.stewardacs.xyz/mcp/sse"
    }
  }
}
```

- `steward` has **no headers** — Cursor runs the OAuth (Auth0) browser flow on first connect.
- Both servers expose the same `acs_*` tools. When you only want one, disable the other in Cursor's MCP settings (gear icon per server).

### Codex

File: `.codex/config.toml` (activate with `CODEX_HOME="$PWD/.codex" codex`).

```toml
[mcp_servers.acs]
url = "http://localhost:4001/mcp/v1/messages"
[mcp_servers.acs.http_headers]
"x-api-key" = "<local-acs-api-key>"

[mcp_servers.steward]
url = "https://anantha.stewardacs.xyz/mcp/sse"
```

- Codex performs the OAuth flow for `steward` automatically (no `http_headers`).
- Approval modes for the shared tools (`claim_work`, `connection_diagnostic`, `specs_propose`) are set per server — keep them on both.

## How to know you're on the right instance

- `steward` → any memory/task you save lands in the anantha org (visible in the anantha dashboard at `https://anantha.stewardacs.xyz`).
- `acs` → connects to your local Phoenix server; only use it when you have local code changes to exercise.
- When a task or memory is missing from remote but "exists" locally, you saved it to the wrong server.

## Local-only testing loop

1. Make the code change (stay on `dev`, no branch switching).
2. Boot the local instance: `docker compose up -d` (URL `http://localhost:4001`).
3. Point Cursor/Codex at `acs` only (disable `steward`) to exercise the change against the test sandbox.
4. Never create/claim production tasks against local. After the change is validated, switch back to `steward` for the real task state.

## After any work

Follow `AGENTS_STEWARD.md` "After Work": save to the **remote** instance (skill_save / specs_propose / save_memory), then `acs_release_work` + `acs_submit_task_feedback` last.

## Troubleshooting

- **"Authorization server issuer mismatch: expected https://anantha.stewardacs.xyz/, received https://dev-jw5wgp2b.us.auth0.com/"** — the authorization-server metadata `issuer` must equal the host the metadata was fetched from (RFC 8414 §2.1). Caddy must serve `"issuer":"https://{host}/"`, not `{$AUTH0_DOMAIN}`. Fix in `Caddyfile.multitenant`, then redeploy/reload Caddy. Server-side JWT validation is unaffected (it validates against the Auth0 issuer directly).
- **"Protected resource metadata resource mismatch: reference '.../mcp/coding/sse', permitted '.../mcp/sse'"** — OAuth connectors must use `/mcp/sse` (the Auth0 resource identifier), not the `/mcp/coding/sse` alias. Point the remote server at `https://anantha.stewardacs.xyz/mcp/sse`.
- **Remote won't connect / 401** — complete the OAuth browser flow; the bearer token must be fresh. Reconnect the connector after a redeploy (JWT is short-lived).
- **"Service not found: https://anantha.stewardacs.xyz/mcp/sse"** — the Auth0 API audience for the org is missing. Run `EXTRA_ORG_SLUGS=anantha ./scripts/ensure-auth0-org-audiences.sh`.
- **Duplicated tools** — both servers are enabled; disable the one you aren't using.
- **Local fails to boot** — see `guides/deployment.md` (SQLite, port 4001, `OAUTH_BEARER_ENABLED=false` locally).
