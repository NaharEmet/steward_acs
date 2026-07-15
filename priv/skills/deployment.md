---
name: "deployment"
description: Deploy and operate Steward ACS (local + multi-tenant prod).
audit_reasoning: "The skill provides clear, concrete commands and tables for deployment scenarios, with verification steps. It is distinct from existing skills (auth0-users, secrets, steward-installer) and covers a unique operational workflow. Minor gaps exist in failure recovery and prerequisites."
audit_score: 8
audit_status: "ok"
audited_at: "2026-07-15T14:43:57.368487Z"
---

# Deployment

## Supported commands

```bash
# Local
docker compose up -d

# Prod SQLite (canonical)
cp .env.multitenant .env   # fill secrets
docker compose -f docker-compose.multitenant.yml up -d

# Prod Postgres override
docker compose -f docker-compose.multitenant.yml -f docker-compose.postgres.yml up -d

# Immutable remote deploy (from laptop)
SERVER=ubuntu@HOST ./scripts/deploy.sh
SERVER=ubuntu@HOST ./scripts/status.sh
SERVER=ubuntu@HOST ./scripts/backup-prod.sh
```

| Setup | Compose | Notes |
|-------|---------|-------|
| Local | `docker-compose.yml` | SQLite, port 4001 |
| Prod SQLite | `docker-compose.multitenant.yml` + `Caddyfile.multitenant` | Current stewardacs prod |
| Prod Postgres | above + `docker-compose.postgres.yml` | For upcoming migration |

Older `cloudflare` / `remote` / `prod` compose files live under `archive/deploy/` and must not be used.

## Env templates

- Local: `.env.example` → `.env`
- Prod: `.env.multitenant` → `.env`
- Multi-org dashboard logins: `ACS_ORG_DASHBOARD_CREDS='{"prod":{"username":"admin","password":"..."}}'`
- Auth0 M2M: `AUTH0_MGMT_CLIENT_ID` / `AUTH0_MGMT_CLIENT_SECRET` (aliases: `AUTH0_M2M_*`). Keep in `pass`, never in git.

## Migrations

Release entrypoint runs `Acs.Release.migrate` on start. Manual:

```bash
docker compose -f docker-compose.multitenant.yml exec steward_acs \
  /app/bin/steward_acs eval "Acs.Release.migrate"
```

Do **not** use `mix ecto.migrate` against the release image (no Mix).

## Syncthing

Admin UI is loopback-only (`127.0.0.1:8384`). Tunnel:

```bash
ssh -L 8384:127.0.0.1:8384 ubuntu@HOST
```

Device sync uses published `22000` / `21027/udp`. Do not reverse-proxy Syncthing admin through Caddy.

## Orgs

`ORGS_FILE=/data/orgs.yaml`. `create_org` updates that file. If empty after upgrade, seed once:

```bash
docker cp priv/orgs.yaml steward_acs:/data/orgs.yaml
```

## Smoke checks after deploy

1. `./scripts/status.sh` with `SERVER=` set — digest healthy, expected image SHA
2. `curl -fsS https://prod.stewardacs.xyz/mcp/health`
3. Dashboard login for configured org + `/skills` (no 500)
4. `/.well-known/oauth-protected-resource/mcp/sse` if OAuth enabled
5. No `inotify-tools` errors in `docker logs steward_acs`
