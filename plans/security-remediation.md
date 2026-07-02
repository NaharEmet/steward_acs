# Security Remediation Plan

Status as of 2026-07-02. Items marked **DONE** were fixed in this pass.

## P0 — Fixed

| ID | Issue | Status | Change |
|----|-------|--------|--------|
| C1 | `exec_command` arg path bypass | **DONE** | Tool removed entirely |
| C2 | Arbitrary SQL via `query` tool | **DONE** | Read-only validation (SELECT/WITH/EXPLAIN only) |
| C4 | Localhost auth bypass grants admin | **MITIGATED** | Enabled only in dev (`mcp_auth_local_fallback: true`); disabled in prod; `/mcp/health` unauthenticated for probes |

## P1 — Fixed

| ID | Issue | Status | Change |
|----|-------|--------|--------|
| H1 | Hybrid search bypasses ABAC | **DONE** | Pass full ABAC opts to `Indexer.search/2` |
| H2 | ABAC fail-open for collaborators | **DONE** | Fail-closed to `visibility=org` for collaborator/reader |
| H3 | `ask` document search has no ABAC | **DONE** | Filter cognition entries by visibility/team/project |
| H4 | Path prefix bypass in filesystem tools | **DONE** | Boundary check (`allowed` or `allowed/...`) |
| H8 | Memory `scope_path` traversal | **DONE** | Reject `..` and absolute paths in validate + loader |
| C3 | Broken Dockerfile | **DONE** | Multi-stage `dev` + `release` targets, non-root runtime, migrate entrypoint |
| H5 | Symlink escape in filesystem tools | **DONE** | `File.realpath/1` before path allowlist check |
| H7 | SSRF via `write_tool` + Bridge | **DONE** | `Acs.MCP.UrlSafety` + optional `BRIDGE_ALLOWED_HOSTS` |
| H9 | Placeholder secrets in docker-compose | **DONE** | Remote compose requires `${VAR:?}`; local uses dev-only secret |
| H10 | Static session cookie signing salt | **DONE** | `COOKIE_SIGNING_SALT` via `runtime.exs` |

## P1 — Remaining

| ID | Issue | Severity | Recommended fix |
|----|-------|----------|-----------------|
| — | (none) | — | — |

## P2 — Remaining

| ID | Issue | Severity | Recommended fix |
|----|-------|----------|-----------------|
| M1 | No TLS / HSTS | **DONE** | `force_ssl` in prod with `x_forwarded_proto` behind Caddy |
| M2 | Rate limiting IP-only | **DONE** | Hashed API key + path; atomic `:ets.update_counter` |
| M4 | Logs exposed to any API-key holder | **DONE** | Requires `admin` or `service` role |
| M5 | Agent identity spoofing | **DONE** | `_auth_agent_id` from key; non-admin `agent_id` must match |
| M6 | Developer keys default to admin | **DONE** | Default role is `collaborator` |
| M7 | Magic link in URL (GET) | **DONE** | GET shows confirm form; POST redeems; TTL 15 minutes |
| M8 | Log API DoS via invalid `level` | **DONE** | Allowlist validation returns 400 |
| M9 | `.env` loaded from CWD | **DONE** | `ENV_PATH` or repo-relative path; skip if missing |
| M10 | Public ETS stores API keys | **DONE** | Bridge session table is `:protected` |
| M11 | LIKE wildcard on scope_path | **DONE** | Reject `%`/`_` wildcards (exact match fallback) |
| M12 | Dashboard 500 on unauthenticated access | **DONE** | Fixed `ErrorHTML` + `assign_new` in `user_auth.ex` |
| M13 | Dev mailbox exposes magic links | **DONE** | `dev_routes` compile-time gate + `LocalhostOnly` on `/dev/*` |

## P3 — Backlog

| ID | Issue | Notes |
|----|-------|-------|
| L1 | OAuth Bearer stub | **DONE** | Removed from default auth chain; opt-in via `OAUTH_BEARER_ENABLED=true` |
| L2 | Core-tool RBAC inconsistent with YAML | **DONE** | `Acs.MCP.CoreToolRoles` used by `authorize_tool` and `list_tools_mcp` |
| L4 | `acs_time` clock manipulation | **DONE** | `set` restricted to admin/service; collaborators may `get` only |
| L5 | Postgres default credentials | **DONE** | `runtime.exs` raises if default `postgres` password in prod |
| L6 | Dashboard default credentials | **DONE** | `runtime.exs` raises if `ACS_PASSWORD` is default `admin` in prod |
| L7 | Dev routes exposed on LAN | **DONE** | `/dev/*` gated by `LocalhostOnly` plug |

## Verification checklist

After deploying fixes:

- [ ] `GET /mcp/health` returns 200 without API key
- [ ] `POST /mcp/v1/messages` without key returns 401
- [ ] `query` tool rejects `INSERT`, `DELETE`, `DROP`
- [ ] Collaborator key with no team list sees only `visibility=org` memories
- [ ] `read_file` rejects `/tmp_extra/...` when `/tmp` is allowed
- [ ] `save_memory` rejects `scope_path: "../../etc"`
- [ ] Docker healthcheck passes without MCP API key

## Next recommended sprint

1. Implement OAuth Bearer OIDC validation when `OAUTH_BEARER_ENABLED=true`
2. Align dynamically written YAML tools with role defaults on approval
3. Rotate `ACS_PASSWORD` / `PGPASSWORD` in deployed environments
