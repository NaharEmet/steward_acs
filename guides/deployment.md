# Deployment

Supported setups (only these three):

| Setup | Command |
|-------|---------|
| Local dev | `docker compose up -d` |
| Multi-tenant prod (SQLite) | `docker compose -f docker-compose.multitenant.yml up -d` |
| Multi-tenant prod (Postgres) | `docker compose -f docker-compose.multitenant.yml -f docker-compose.postgres.yml up -d` |

Agent-facing detail lives in [`priv/skills/deployment.md`](../priv/skills/deployment.md). Keep that skill current; this guide is the human index.

## Local development

```bash
cp .env.example .env
# configure Auth0 web credentials; optionally set LLM keys
docker compose up -d
# or: mix phx.server  (loads .env via config/runtime.exs)
```

- Compose: [`docker-compose.yml`](../docker-compose.yml)
- DB: SQLite
- URL: `http://localhost:4001`

## Multi-tenant production (canonical)

```bash
cp .env.multitenant .env
# fill SECRET_KEY_BASE, MCP_API_KEY, Auth0 web credentials, Syncthing keys, and MCP OAuth as needed
# register https://${ACCOUNT_HOST}/auth/callback in the Auth0 Regular Web Application
# ACCOUNT_HOST should be the ACS app host (prod.stewardacs.xyz), not the Astro apex
docker compose -f docker-compose.multitenant.yml up -d
```

Or deploy from a workstation with an immutable Git-SHA tag (clean tree required):

```bash
SERVER=ubuntu@YOUR_HOST ./scripts/deploy.sh
SERVER=ubuntu@YOUR_HOST ./scripts/status.sh
SERVER=ubuntu@YOUR_HOST ./scripts/backup-prod.sh

# Dirty hotfix / resume / rollback
ALLOW_DIRTY=1 SERVER=ubuntu@YOUR_HOST ./scripts/deploy.sh
SERVER=ubuntu@YOUR_HOST ACS_IMAGE_TAG=<tag> ./scripts/deploy.sh --resume
SERVER=ubuntu@YOUR_HOST ./scripts/deploy.sh --rollback
```

`deploy.sh` cutover is a single SSH session (survives fewer mid-deploy drops). Images carry `org.opencontainers.image.revision` + `.dirty` labels for `status.sh`.

### GitHub Actions + new servers

```bash
# One-time new host
SERVER=ubuntu@NEW_HOST ./scripts/bootstrap-server.sh
# fill secrets in remote .env, then:
SERVER=ubuntu@NEW_HOST ACS_IMAGE_TAG=<sha> ./scripts/bootstrap-server.sh --start
```

CI: [`.github/workflows/deploy.yml`](../.github/workflows/deploy.yml) builds/pushes the image and runs `deploy.sh --resume` against the GitHub Environment’s `DEPLOY_HOST`. Add Environment secrets (`DEPLOY_HOST`, `DEPLOY_USER`, `SSH_PRIVATE_KEY`, `DOCKERHUB_*`) per server/stage.

| Aspect | Value |
|--------|-------|
| Compose | `docker-compose.multitenant.yml` |
| Caddy | `Caddyfile.multitenant` |
| Env template | `.env.multitenant` |
| Image | `naharemete/steward_acs:${ACS_IMAGE_TAG:-multitenant}` |
| DB (default) | SQLite at `/data/steward.sqlite` |
| Memory | Obsidian vaults under `/vaults` |
| Auth | API/developer keys for services; Auth0 OIDC for individual dashboard users and human MCP access |
| Syncthing admin | **Not** on public HTTPS — SSH tunnel to `127.0.0.1:8384` |

### Per-organization vault folders

Every organization, including the configured `ACS_ORG_NAME`, has a non-overlapping canonical root:

```text
/vaults/orgs/<slug>/
  private/memories/
  skills/
  specs/
  prompts/
  acstools/
```

Point each Syncthing folder at exactly `/var/syncthing/vaults/orgs/<slug>`. Never point an organization at the parent `/var/syncthing/vaults`: that parent contains every tenant and would disclose their files. `SPECS_PATH`, when set, remains a compatibility base but still partitions every organization beneath `SPECS_PATH/orgs/<slug>`; unset it to use the unified vault tree.

The application reads canonical files before legacy files during migration and writes only to the canonical tree. Migrate one non-configured tenant at a time, and migrate the configured legacy tenant last. Stop writers or pause Syncthing first, take a backup, then use `rsync` so the operation is repeatable and preserves the source for rollback:

```bash
slug=acme
mkdir -p "/vaults/orgs/$slug"/{private/memories,skills,specs,prompts,acstools}
rsync -a --dry-run "/vaults/skills/orgs/$slug/" "/vaults/orgs/$slug/skills/"
rsync -a --dry-run "/vaults/specs/orgs/$slug/"  "/vaults/orgs/$slug/specs/"
rsync -a --dry-run "/vaults/$slug/prompts/"      "/vaults/orgs/$slug/prompts/"
# Remove --dry-run only after reviewing the file list, then compare counts/hashes.
```

For the configured legacy organization, also copy `/vaults/private/memories/` into its canonical `private/memories/` directory. If its slug is `default`, its old skills/specs roots are `/vaults/skills/` and `/vaults/specs/`; copy only files owned by `default` and exclude their nested `orgs/` directories. Keep legacy sources through the rollback window; do not use `mv` while Syncthing peers may still reference the old paths.

`MCP_TOOLS_PATH` and `EXTERNAL_TOOLS_PATH` are read-only shared/plugin sources; tenant writes never target them. Tenant YAML may define HTTP endpoints only. Shared YAML handlers are disabled unless each module is explicitly listed in the comma-separated `TRUSTED_MCP_HANDLER_MODULES` allowlist.

### Postgres override (planned prod migration)

```bash
# same .env plus DB_PASSWORD=
docker compose -f docker-compose.multitenant.yml -f docker-compose.postgres.yml up -d
```

Entry point runs release migrations on boot. Manual recovery:

```bash
docker compose -f docker-compose.multitenant.yml exec steward_acs \
  /app/bin/steward_acs eval "Acs.Release.migrate"
```

### Org registry

`ORGS_FILE=/data/orgs.yaml` (volume). Seed from `priv/orgs.yaml` once if the volume copy is missing:

```bash
docker cp priv/orgs.yaml steward_acs:/data/orgs.yaml
```

After deploying the organization migration, import that registry into the database before enabling OAuth-only access:

```bash
docker compose -f docker-compose.multitenant.yml exec steward_acs \
  /app/bin/steward_acs eval 'Acs.Release.import_organizations()'
```

Have each existing organization owner sign in once on `ACCOUNT_HOST`, then bootstrap the verified OAuth identity and invalidate the old shared-login workflow:

```bash
docker compose -f docker-compose.multitenant.yml exec steward_acs \
  /app/bin/steward_acs eval 'Acs.Release.bootstrap_owner("owner@example.com", "org-slug")'
```

Keep `SELF_SERVICE_ORGS_ENABLED=false` until imports, owner bootstrap, wildcard DNS/TLS, and Auth0 callback settings are verified. New invitations initially expose a single-use link to the administrator for delivery; only the hash is stored.

### Axiom observability

Production can export inbound HTTP/Phoenix/Ecto traces and structured application logs to Axiom. Create an **Events** dataset in Axiom once, then set these values in the untracked production `.env`:

```bash
AXIOM_LOGS=xaat-your-ingest-token
AXIOM_DATASET=steward-acs
# AXIOM_DOMAIN=https://api.axiom.co  # only needed for an Axiom edge deployment
```

Export is enabled only when the release runs in `prod` and `AXIOM_LOGS` is non-empty. Development and test never ship telemetry, even when a local `.env` contains the token. Keep the token ingest-scoped to the configured dataset.

After deploying, request `/mcp/health`, exercise a database-backed route, and confirm both traces and log events arrive in the dataset. HTTP query-string values are redacted from spans. Every ~30s, `message == "vm.metrics"` events ship BEAM memory/`scheduler_utilization` plus best-effort Linux host fields (`host_memory_*_bytes` from `/proc/meminfo`, `cgroup_memory_*_bytes` / `cgroup_cpu_utilization` from the process cgroup). These are Events-dataset rows, not a separate OTLP metrics stream. Full bare-metal host telemetry (disk, NICs, other processes) still needs a host agent.

### Secrets

Use `pass` / untracked `.env` only. Never commit Axiom or Auth0 tokens. See [`guides/secrets.md`](secrets.md).

Archived older compose files: [`archive/deploy/`](../archive/deploy/).
