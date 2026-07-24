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
- Dashboard Auth0 OIDC: `OIDC_BROWSER_ENABLED`, `ACCOUNT_HOST`, and the `AUTH0_WEB_*` values from a Regular Web Application.
- Self-service org creation: keep `SELF_SERVICE_ORGS_ENABLED=false` through migration/bootstrap, then enable deliberately.
- Auth0 M2M: `AUTH0_MGMT_CLIENT_ID` / `AUTH0_MGMT_CLIENT_SECRET` (aliases: `AUTH0_M2M_*`). Keep in `pass`, never in git.
- Axiom (optional): `AXIOM_LOGS` (ingest token), `AXIOM_DATASET` (defaults to `steward-acs`), and `AXIOM_DOMAIN` only for edge deployments. Export is strictly prod-only and disabled without the token.

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

Organizations are database-backed. During the OAuth migration, import the legacy registry once, then bootstrap each verified owner's identity after their first OIDC login:

```bash
docker compose -f docker-compose.multitenant.yml exec steward_acs \
  /app/bin/steward_acs eval 'Acs.Release.import_organizations()'

docker compose -f docker-compose.multitenant.yml exec steward_acs \
  /app/bin/steward_acs eval 'Acs.Release.bootstrap_owner("owner@example.com", "org-slug")'
```

The YAML registry remains a read-only compatibility fallback during rollout. New organizations come from onboarding; MCP `create_org` and `create_user` are deprecated.

## Smoke checks after deploy

1. `./scripts/status.sh` with `SERVER=` set — digest healthy, expected image SHA
2. `curl -fsS https://prod.stewardacs.xyz/mcp/health`
3. Auth0 login on `ACCOUNT_HOST`, account onboarding, and tenant `/skills`
4. Invite a member, copy the one-time link, accept with the exact verified email, and verify `/settings/members`
5. `/.well-known/oauth-protected-resource/mcp/sse` if OAuth enabled
6. No `inotify-tools` errors in `docker logs steward_acs`
7. If `AXIOM_LOGS` is set, traces and log events appear in the configured Axiom dataset after the health request
