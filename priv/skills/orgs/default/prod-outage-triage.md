---
description: "Triage a reported Steward ACS production outage using public health checks, MCP guard checks, and host status when SSH is available."
name: "prod-outage-triage"
proposed_by: "nahar emet"
scope_paths: ["steward_acs/production", "guides/deployment"]
status: "approved"
tags: ["deployment", "ops", "outage", "prod"]
when_to_use: "Use when someone reports prod Steward ACS is down or unreachable."
audit_reasoning: "The skill is highly actionable, complete, and well-structured for its intended 'coding' audience. It provides clear, numbered steps with exact commands, prerequisites, verification criteria, and failure recovery guidance. The description is distinct and informative, and the content includes concrete examples (file paths, commands, tool names). It is unique among the existing skills and does not duplicate any of them. The scope is appropriately focused on production outage triage."
audit_score: 10
audit_status: "ok"
audited_at: "2026-08-07T06:58:54.830263Z"
approved_at: "2026-08-07T06:58:54.835553Z"
approved_by: "llm"
reviewed_at: "2026-08-07T06:58:54.835553Z"
reviewed_by: "llm"
---

# Prod Outage Triage

## When to use

Use this when someone reports `prod.stewardacs.xyz` or a tenant subdomain is down.

## Prerequisites

- Work from the `dev` branch unless the user explicitly asks to deploy/promote.
- Load the `deployment` skill or `guides/deployment.md` first.
- Do not print secret values from `.env` or Infisical.
- If SSH to the prod host is available, use read-only checks before recovery commands.

## Steps

1. Create and claim an ACS task for the incident.
2. Confirm the current branch with `git branch --show-current`; stop and ask if it is not `dev`.
3. Check public app and DB health:
   ```bash
   curl -i --max-time 15 https://prod.stewardacs.xyz/mcp/health
   ```
   Healthy output is HTTP 200 with JSON including `"status":"healthy"` and `"database":true`.
4. Check the web root:
   ```bash
   curl -I --max-time 15 https://prod.stewardacs.xyz/
   ```
   HTTP 200 means Phoenix/Caddy/Cloudflare are serving the UI.
5. Check MCP guard behavior without credentials:
   ```bash
   curl -i --max-time 15 https://prod.stewardacs.xyz/mcp/sse
   curl -i --max-time 15 https://prod.stewardacs.xyz/mcp/chat/sse
   ```
   HTTP 401 with `Missing or invalid API key` means the MCP path is reachable and protected; it is not an outage by itself.
6. Check OAuth protected-resource metadata if OAuth clients are failing:
   ```bash
   curl -sS -o /dev/null -w '%{http_code} %{time_total}\n' --max-time 15 \
     https://prod.stewardacs.xyz/.well-known/oauth-protected-resource/mcp/sse
   ```
7. Check affected tenant subdomains explicitly, for example:
   ```bash
   curl -i --max-time 15 https://safetyconnect.stewardacs.xyz/mcp/health
   ```
8. If public checks show failure, run host status when SSH is available:
   ```bash
   SERVER=ubuntu@HOST ./scripts/status.sh
   ```
   Inspect `health`, `acs_container`, `env_required_missing`, `image_git_sha`, and `db_backend`.
9. If SSH hangs or the sandbox blocks port 22, retry a direct non-interactive probe outside the sandbox approval flow:
   ```bash
   ssh -o BatchMode=yes -o ConnectTimeout=8 ubuntu@HOST true
   ```
10. Recover only after identifying the failed layer. Prefer GitHub Actions deploy/cutover. Use `deploy.sh --resume` or `--rollback` only as break-glass, per the `deployment` skill.

## Verification

- Public `/mcp/health` returns 200 with `database:true`.
- Root page returns 200.
- Unauthenticated `/mcp/sse` returns 401, not 5xx or timeout.
- Affected tenant health endpoints return 200.
- If SSH was available, `scripts/status.sh` reports a healthy active container and no missing required env.

## Common failures

- Public health is green but the user sees an error: ask for the exact URL, tenant, client, timestamp, and error message; likely auth/client-specific rather than global outage.
- SSH to the example host times out: do not assume app down; Cloudflare/Caddy public checks may still be healthy. Verify the actual DEPLOY_HOST from GitHub Environment or operator docs.
- Local shell forms using nested `bash -lc` or command substitution can behave differently under sandboxed DNS. Prefer direct `curl` public checks for incident signal.
