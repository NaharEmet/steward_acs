---
description: Local .env vs Infisical for multi-tenant prod secrets
name: "secrets"
scope_paths: ["guides/secrets", "guides/deployment", "config", "scripts"]
when_to_use: Before touching .env, deploying, or storing credentials — never commit secrets to git
tags: ["secrets", "infisical", "deploy", "env"]
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

```bash
# On the prod host (or via scripts/deploy.sh cutover):
./scripts/infisical-compose.sh -f docker-compose.multitenant.yml up -d
```

`deploy.sh` syncs `scripts/infisical-compose.sh` and runs compose through it.

### Agent / MCP

Cursor project MCP (`.cursor/mcp.json`, gitignored) can use Infisical Universal Auth to create/list secret **names**. Do not print secret values into chat. Confirm fills by name presence / “not REPLACE_ME”, not by dumping values.

## Ops Auth0 M2M (not ACS runtime)

`./scripts/setup-auth0.sh` and related scripts use `AUTH0_M2M_*` / `certs/Oauth.md`. Those are **not** loaded by the ACS app.

## Never commit live credentials

Tracked templates (`.env.example`, `.env.multitenant`, `.env.remote`) keep secrets empty. If a secret lands in git, rotate it in the provider and scrub history.
