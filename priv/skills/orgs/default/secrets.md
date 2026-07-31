---
description: Local .env vs Infisical for multi-tenant prod secrets
name: "secrets"
scope_paths: ["guides/secrets", "guides/deployment", "config", "scripts"]
when_to_use: Before touching .env, deploying, or storing credentials — never commit secrets to git
tags: ["secrets", "infisical", "deploy", "env"]
audit_reasoning: "The skill is highly actionable for a coding agent, with clear, ordered steps, concrete file paths, commands, and tool references (Infisical MCP, docker compose). It covers local and prod environments, includes verification (e.g., checking for REPLACE_ME), and failure recovery (e.g., break-glass deploy). The description is distinct and informative. The only minor gap is an explicit prerequisites section, but the content implies them (e.g., having .env.example, Infisical access)."
audit_score: 8
audit_status: "ok"
audited_at: "2026-07-31T04:13:19.815659Z"
approved_at: "2026-07-31T04:13:19.842070Z"
approved_by: "llm"
reviewed_at: "2026-07-31T04:13:19.842070Z"
reviewed_by: "llm"
status: "approved"
---

# Secrets Management

Two paths only:

| Environment | Source of truth |
|-------------|-----------------|
| **Local** (`docker compose` / `mix phx.server`) | Untracked `.env` (from `.env.example`) |
| **Multi-tenant prod** | Infisical project `steward_prod` → env `prod` |

Do **not** use `pass` for ACS. Do **not** put prod secrets in the server `.env`.

## Local

```bash
cp .env.example .env
# fill keys you need for local (SQLite; no Neon DATABASE_URL)
chmod 600 .env
docker compose up -d
# or: mix phx.server
```

Never commit `.env`. Never copy Infisical prod secrets into local `.env`.

## Prod (Infisical)

Secrets (and optional placeholders) live in Infisical. Agents may create/list **names** via Infisical MCP; humans paste **values** in the Infisical UI. Leave unused keys as blank or `REPLACE_ME` — inject skips those.

### Host files (thin)

| File | Purpose |
|------|---------|
| `.env` | Non-secret config only (hosts, `ACS_IMAGE_TAG`, flags). Template: `.env.multitenant` |
| `.infisical.env` | Read-only machine identity (`INFISICAL_UNIVERSAL_AUTH_CLIENT_ID` / `_SECRET`). Mode 600. Never commit. |
| `.env.infisical` | Generated at deploy time by `scripts/infisical-compose.sh` (gitignored). |

### Deploy / compose

Prod cutover is **GitHub Actions** (`.github/workflows/deploy.yml` → `deploy.sh --resume`). That syncs `scripts/infisical-compose.sh` and runs compose through it.

```bash
# On the prod host (manual recreate / debug only):
./scripts/infisical-compose.sh -f docker-compose.multitenant.yml up -d
```

Laptop `SERVER=… ./scripts/deploy.sh` is break-glass only — see `guides/deployment.md`.

### Agent / MCP

Cursor project MCP (`.cursor/mcp.json`, gitignored) can use Infisical Universal Auth to create/list secret **names**. Do not print secret values into chat. Confirm fills by name presence / “not REPLACE_ME”, not by dumping values.

## Ops Auth0 M2M (not ACS runtime)

`./scripts/setup-auth0.sh` and related scripts use `AUTH0_M2M_*` / `certs/Oauth.md`. Those are **not** loaded by the ACS app.

## Never commit live credentials

Tracked templates (`.env.example`, `.env.multitenant`, `.env.remote`) keep secrets empty. If a secret lands in git, rotate it in the provider and scrub history.
