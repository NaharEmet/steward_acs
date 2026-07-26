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
cp .env.example .env   # local secrets only — never Neon/prod Auth0
docker compose up -d

# Prod Neon Postgres (canonical) — secrets from Infisical
# Host: thin .env from .env.multitenant + .infisical.env (machine identity)
./scripts/infisical-compose.sh -f docker-compose.multitenant.yml up -d

# Optional: local Postgres container instead of Neon
./scripts/infisical-compose.sh -f docker-compose.multitenant.yml -f docker-compose.postgres.yml up -d
# or: WITH_POSTGRES=true SERVER=ubuntu@HOST ./scripts/deploy.sh

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
# then write REMOTE_DIR/.infisical.env (machine identity), confirm Infisical prod secrets, then:
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
| Prod Neon | `docker-compose.multitenant.yml` + `Caddyfile.multitenant` | Canonical; set `DATABASE_URL` |
| Local Postgres override | above + `docker-compose.postgres.yml` | Optional; `WITH_POSTGRES=true` |

Older `cloudflare` / `remote` / `prod` compose files live under `archive/deploy/` and must not be used.

## Env templates

- Local: `.env.example` → `.env` (all local secrets here)
- Prod thin config: `.env.multitenant` → host `.env` (non-secrets only: hosts, `ACS_IMAGE_TAG`, flags)
- Prod secrets: Infisical `steward_prod` / `prod` via `scripts/infisical-compose.sh`
- Host Infisical agent: `.infisical.env` with Universal Auth machine identity (read-only)
- Neon: `DATABASE_URL` in Infisical (pooled string preferred); `PGSSL` / `POOL_SIZE` may be thin `.env`
- Dashboard Auth0 OIDC: `AUTH0_WEB_*` in Infisical; `ACCOUNT_HOST` / callback URI in thin `.env`
- Self-service org creation: keep `SELF_SERVICE_ORGS_ENABLED=false` through migration/bootstrap, then enable deliberately.
- Auth0 M2M for ops scripts only (`./scripts/setup-auth0.sh`, etc.): `AUTH0_M2M_*` / `certs/Oauth.md` — not loaded by the ACS app.
- Axiom (optional): `AXIOM_LOGS` in Infisical; `AXIOM_DATASET` may be thin `.env`. Export is strictly prod-only and disabled without the token.

## Migrations

Release entrypoint runs `Acs.Release.migrate` on start. Manual:

```bash
docker compose -f docker-compose.multitenant.yml exec steward_acs \
  /app/bin/steward_acs eval "Acs.Release.migrate"
```

Do **not** use `mix ecto.migrate` against the release image (no Mix).

## Backups

- **DB:** Neon PITR / console export (not `backup-prod.sh`).
- **Vaults + orgs.yaml:** `SERVER=ubuntu@HOST ./scripts/backup-prod.sh`
## Syncthing

Admin UI is loopback-only (`127.0.0.1:8384`). Tunnel:

```bash
ssh -L 8384:127.0.0.1:8384 ubuntu@HOST
```

Device sync uses published `22000` / `21027/udp`. Do not reverse-proxy Syncthing admin through Caddy.

Each organization uses the non-overlapping folder `/var/syncthing/vaults/orgs/<slug>`, containing `private/memories`, `skills`, `specs`, `prompts`, and `acstools`. Never configure `/var/syncthing/vaults` itself as a tenant folder because it contains all organizations. Canonical files override legacy locations during migration; ACS writes only to the canonical tree. Use backup plus repeatable `rsync --dry-run`/`rsync` copies, migrate a non-configured tenant first, and keep legacy sources for rollback. When set, `SPECS_PATH` remains tenant-partitioned beneath `SPECS_PATH/orgs/<slug>`.

## Orgs

Organizations are database-backed. During the OAuth migration, import the legacy registry once, then bootstrap each verified owner's identity after their first OIDC login:

```bash
docker compose -f docker-compose.multitenant.yml exec steward_acs \
  /app/bin/steward_acs eval 'Acs.Release.import_organizations()'

docker compose -f docker-compose.multitenant.yml exec steward_acs \
  /app/bin/steward_acs eval 'Acs.Release.bootstrap_owner("owner@example.com", "org-slug")'
```

The YAML registry remains a read-only compatibility fallback during rollout. New organizations come from onboarding; MCP `create_org` is deprecated. Claude Connector users are created in Auth0 (dashboard or `./scripts/setup-auth0.sh`), not via ACS.

## Smoke checks after deploy

`deploy.sh` already checks container health + public `/mcp/health` (and fixed DCR when configured). Still verify:

1. `SERVER=ubuntu@HOST ./scripts/status.sh` — `health=healthy`, `image_git_sha` matches tag, `env_required_missing=` empty, `compose_wires_oauth_fixed_dcr` matches whether fixed DCR is intended
2. Auth0 login on `ACCOUNT_HOST`, account onboarding, and tenant `/skills`
3. Invite a member, copy the one-time link, accept with the exact verified email, and verify `/settings/members`
4. `/.well-known/oauth-protected-resource/mcp/sse` if OAuth enabled
5. No `inotify-tools` errors in `docker logs steward_acs`
6. If `AXIOM_LOGS` is set, traces and log events appear in the configured Axiom dataset after the health request. After deploy, `message == "vm.metrics"` events appear every ~30s (BEAM memory + scheduler utilization).

## Agent deploy rules

- Prefer **commit → deploy**. Dirty deploys need `ALLOW_DIRTY=1`.
- Never re-add a DCR prune GenServer; prevention is fixed client + ACS-owned `/oidc/register`.
- Partial failure after image push: `--resume`. Bad cutover: `--rollback`.
