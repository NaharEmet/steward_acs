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

# Immutable remote deploy (from laptop) — clean tree required
SERVER=ubuntu@HOST ./scripts/deploy.sh
SERVER=ubuntu@HOST ./scripts/status.sh
SERVER=ubuntu@HOST ./scripts/backup-prod.sh

# Hotfix from dirty tree (unique tag + --no-cache)
ALLOW_DIRTY=1 SERVER=ubuntu@HOST ./scripts/deploy.sh

# CI / agent: build+push only, then cut over
./scripts/deploy.sh --push-only
SERVER=ubuntu@HOST ACS_IMAGE_TAG=<tag> ./scripts/deploy.sh --resume

# SSH dropped after push / mid-cutover
SERVER=ubuntu@HOST ACS_IMAGE_TAG=<tag> ./scripts/deploy.sh --resume

# Undo last pin (uses ACS_IMAGE_TAG_PREV on the server)
SERVER=ubuntu@HOST ./scripts/deploy.sh --rollback

# New server (once)
SERVER=ubuntu@NEW_HOST ./scripts/bootstrap-server.sh
# fill .env on the host, then:
SERVER=ubuntu@NEW_HOST ACS_IMAGE_TAG=<tag> ./scripts/bootstrap-server.sh --start
```

Deploy builds once, pushes a Git-SHA tag, syncs compose/caddy, then **one SSH** for pull + up + caddy recreate + health. Post-deploy smoke hits `/mcp/health` (and `/oidc/register` when `OAUTH_FIXED_DCR_CLIENT_ID` is set on the server). `status.sh` prints `env_has_*` (presence only) plus image revision/dirty labels.

## GitHub Actions

Workflow: [`.github/workflows/deploy.yml`](../../.github/workflows/deploy.yml)

1. Create Environment **prod** (optional **staging**) with secrets: `DEPLOY_HOST`, `DEPLOY_USER`, `SSH_PRIVATE_KEY`, `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`; optional `PUBLIC_URL`, `REMOTE_DIR`; optional variable `REGISTRY`.
2. Push to `main` (relevant paths) or run **Actions → Deploy → Run workflow**.
3. New host: `bootstrap-server.sh` once, add a GitHub Environment pointing at that host, then use the same workflow.

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

`deploy.sh` already checks container health + public `/mcp/health` (and fixed DCR when configured). Still verify:

1. `SERVER=ubuntu@HOST ./scripts/status.sh` — `health=healthy`, `image_git_sha` matches tag, `env_required_missing=` empty, `compose_wires_oauth_fixed_dcr` matches whether fixed DCR is intended
2. Auth0 login on `ACCOUNT_HOST`, account onboarding, and tenant `/skills`
3. Invite a member, copy the one-time link, accept with the exact verified email, and verify `/settings/members`
4. `/.well-known/oauth-protected-resource/mcp/sse` if OAuth enabled
5. No `inotify-tools` errors in `docker logs steward_acs`
6. If `AXIOM_LOGS` is set, traces and log events appear in the configured Axiom dataset after the health request

## Agent deploy rules

- Prefer **commit → deploy**. Dirty deploys need `ALLOW_DIRTY=1`.
- Never re-add a DCR prune GenServer; prevention is fixed client + ACS-owned `/oidc/register`.
- Partial failure after image push: `--resume`. Bad cutover: `--rollback`.
