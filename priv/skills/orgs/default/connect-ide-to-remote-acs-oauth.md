---
description: "Connect Cursor/Codex to the remote ACS instance (anantha) via OAuth and keep local only for testing code changes."
name: "connect-ide-to-remote-acs-oauth"
proposed_by: "nahar emet"
scope_paths: ["guides/development-workflow", "lib/acs/mcp/oauth"]
status: "approved"
tags: ["mcp", "oauth", "cursor", "codex", "connector", "acs"]
when_to_use: "When setting up an IDE/CLI (Cursor, Codex, OpenCode) to use the remote anantha ACS instance via OAuth, or when a connector fails with 401 / missing audience / resource metadata / issuer mismatch."
audit_reasoning: "The skill is exceptionally well-structured and actionable. It provides clear, step-by-step instructions for a specific, repeatable task (connecting an IDE to a remote ACS instance via OAuth). It includes all required sections: prerequisites, detailed steps with exact file paths and configuration examples for multiple IDEs (Cursor, Codex, OpenCode), verification steps, and comprehensive failure recovery. The description is distinct and informative, and the content is perfectly tailored for a 'coding' audience, referencing specific IDE configuration files and commands. It is unique among the existing skills and covers a well-defined scope."
audit_score: 10
audit_status: "ok"
audited_at: "2026-08-07T12:27:47.462730Z"
approved_at: "2026-08-07T12:27:47.471014Z"
approved_by: "llm"
reviewed_at: "2026-08-07T12:27:47.471014Z"
reviewed_by: "llm"
---

# Connect an IDE/CLI to remote ACS via OAuth

## When to use

Setting up Cursor or Codex (or OpenCode) to use the **remote anantha** ACS instance (`https://anantha.stewardacs.xyz`) as the working environment, while keeping the local instance (`http://localhost:4001`) only for testing code changes. Also when a remote connector fails with 401, a missing-audience error, a resource-metadata mismatch, or an issuer mismatch.

## Prerequisites

- Remote instance reachable: `curl -s https://anantha.stewardacs.xyz/mcp/health` → HTTP 200.
- OAuth metadata served: `/.well-known/oauth-protected-resource/mcp/sse` returns `authorization_servers`, `scopes_supported: ["mcp:tools"]`.
- Auth0 audience exists for the org: `https://{slug}.stewardacs.xyz/mcp/sse`. Self-serve orgs may be missing it — fix with `EXTRA_ORG_SLUGS=<slug> ./scripts/ensure-auth0-org-audiences.sh`.
- The connecting user has `mcp:tools` via the "MCP User" role (or dev key).

## Steps

1. **Use `/mcp/sse` for coding connectors** — OAuth connectors (Cursor/Codex/OpenCode) must point at `/mcp/sse`, which is the coding endpoint AND the Auth0 resource identifier the OAuth metadata advertises. The `/mcp/coding/sse` alias fails OAuth strict validation ("resource mismatch"). Chat connectors use `/mcp/chat/sse`.
2. **Cursor** — edit `.cursor/mcp.json`:
   ```json
   {
     "mcpServers": {
       "acs": { "type": "http", "url": "http://localhost:4001/mcp/v1/messages", "headers": { "x-api-key": "<local-acs-api-key>" } },
        "steward": { "type": "http", "url": "https://anantha.stewardacs.xyz/mcp/sse" }
     }
   }
   ```
   No headers on `steward` — Cursor runs the OAuth (Auth0) browser flow on first connect.
3. **Codex** — edit `.codex/config.toml` (activate with `CODEX_HOME="$PWD/.codex" codex`):
   ```toml
   [mcp_servers.steward]
   url = "https://anantha.stewardacs.xyz/mcp/sse"

   [mcp_servers.steward.tools.claim_work]
   approval_mode = "approve"
   # repeat for connection_diagnostic, specs_propose
   ```
   Codex does the OAuth flow automatically; no `http_headers`.
4. **OpenCode** — edit `opencode.json` (project or `~/.config/opencode/opencode.json`):
   ```json
   {
     "mcp": {
       "steward": {
         "type": "remote",
         "url": "https://anantha.stewardacs.xyz/mcp/sse",
         "enabled": true
       }
     }
   }
   ```
   OpenCode runs DCR + the Auth0 browser flow automatically on first use. Trigger manually with `opencode mcp auth steward`; check status with `opencode mcp list`.
5. **Verify** — after connecting, save a memory or create a task on `steward`; confirm it appears in the remote org dashboard (`https://anantha.stewardacs.xyz`). If it only appears locally, you're on the wrong server.
6. **When both servers are enabled**, both expose the same `acs_*` tools — disable the one you aren't using to avoid duplicate tools and cross-store confusion.

## Adding a new connector (universal — no Auth0 setup)

The remote ACS runs an **OAuth broker** (`lib/acs/mcp/oauth/broker.ex`): ACS serves `/authorize`, `/oauth/callback`, and `/token` and accepts **any** client `redirect_uri` (https, or http on loopback) without Auth0 involvement. Auth0 only ever sees the single broker callback `https://{host}/oauth/callback`. So onboarding any new connector/IDE is just pointing it at the MCP URL — no Auth0 callback registration, no `setup-auth0.sh` changes:

1. Add the connector's MCP server config pointing at `https://anantha.stewardacs.xyz/mcp/sse` (see Steps for format per IDE).
2. Connect — the connector runs DCR + the browser flow against the broker.

The MCP server URL is the same for every IDE — only the config file format differs (see Steps): Cursor `.cursor/mcp.json`, Codex `.codex/config.toml`, OpenCode `opencode.json`. Chat connectors use `/mcp/chat/sse`. The only redirect URI registered in Auth0 is the broker's `https://{host}/oauth/callback`.

## Verification

- `curl -sI https://anantha.stewardacs.xyz/mcp/sse` returns `HTTP/2 401` with `www-authenticate: Bearer error="invalid_token", resource_metadata="https://anantha.stewardacs.xyz/.well-known/oauth-protected-resource/mcp/sse"` when unauthenticated — this is expected; the connector supplies the bearer token.
- Successful OAuth connect: connector opens browser, after auth the tool list loads from remote.

## Failure recovery

- **"Authorization server issuer mismatch: expected https://anantha.stewardacs.xyz/, received https://dev-jw5wgp2b.us.auth0.com/"** — the authorization-server metadata `issuer` must equal the host the metadata was fetched from (RFC 8414 §2.1); Caddy must serve `"issuer":"https://{host}/"`, not `{$AUTH0_DOMAIN}`. Fix in `Caddyfile.multitenant` and redeploy/reload Caddy. Server-side JWT validation is unaffected (it validates against the Auth0 issuer directly).
- **"Protected resource metadata resource mismatch: reference '.../mcp/coding/sse', permitted '.../mcp/sse'"** — the connector URL must be `/mcp/sse`, not the `/mcp/coding/sse` alias. Update `.cursor/mcp.json` / `.codex/config.toml` to `https://anantha.stewardacs.xyz/mcp/sse`.
- **401 / "Missing or invalid API key"** — the OAuth flow didn't supply a token, or the token expired. Reconnect the connector (fresh JWT). JWT is short-lived; reconnect after any redeploy.
- **"Service not found: https://anantha.stewardacs.xyz/mcp/sse"** — missing Auth0 API audience. Run `EXTRA_ORG_SLUGS=<slug> ./scripts/ensure-auth0-org-audiences.sh`.
- **Auth0 "Oops!" / Callback URL mismatch / redirect_uri not allowed (any connector)** — this should no longer happen for new connectors because the ACS broker accepts any client `redirect_uri` and relays to Auth0 with the single fixed callback `https://{host}/oauth/callback`. If it still occurs, verify the broker is live (deployed + Caddy routes `/authorize` + `/token` to ACS, not Auth0) and that `https://{host}/oauth/callback` is on the fixed DCR app's allowlist (`scripts/setup-auth0.sh` **Connector Callback Registry**). Legacy per-connector entries can stay in the registry harmlessly.
- **Duplicated tools** — disable the unused server in the IDE's MCP settings.
- **Local won't boot** — see `guides/deployment.md` (SQLite, port 4001, `OAUTH_BEARER_ENABLED=false` locally).
