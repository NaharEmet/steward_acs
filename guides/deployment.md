# Deployment

Supported setups (only these three):

| Setup | Command |
|-------|---------|
| Local dev | `docker compose up -d` |
| Multi-tenant prod (Neon Postgres) | `docker compose -f docker-compose.multitenant.yml up -d` |
| Multi-tenant + local Postgres container | `WITH_POSTGRES=true` / `-f docker-compose.postgres.yml` |

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
# Thin non-secret config on the host
cp .env.multitenant .env
# Secrets: Infisical steward_prod / prod (see guides/secrets.md)
# Machine identity: .infisical.env with INFISICAL_UNIVERSAL_AUTH_CLIENT_ID/_SECRET
# register https://${ACCOUNT_HOST}/auth/callback in the Auth0 Regular Web Application
./scripts/infisical-compose.sh -f docker-compose.multitenant.yml up -d
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

`deploy.sh` cutover is a single SSH session (survives fewer mid-deploy drops). Images carry `org.opencontainers.image.revision` + `.dirty` labels for `status.sh`. Compose on the host runs through `scripts/infisical-compose.sh` (Infisical secrets + thin `.env`).

### Neon database

Prod uses one Postgres database on Neon (`DATABASE_URL` in Infisical `prod`). Prefer Neon's **pooled** connection string. Set `PGSSL=true` in thin `.env` (default in compose). Never commit the URL.

Release entrypoint runs migrations on boot. Manual recovery:

```bash
./scripts/infisical-compose.sh -f docker-compose.multitenant.yml exec steward_acs \
  /app/bin/steward_acs eval "Acs.Release.migrate"
```

### Local Postgres container (optional)

When you want Postgres on the host instead of Neon:

```bash
# same .env plus DB_PASSWORD=; compose override sets DATABASE_URL to the local db
docker compose -f docker-compose.multitenant.yml -f docker-compose.postgres.yml up -d
# or: WITH_POSTGRES=true SERVER=ubuntu@HOST ./scripts/deploy.sh
```

### GitHub Actions + new servers

```bash
# One-time new host
SERVER=ubuntu@NEW_HOST ./scripts/bootstrap-server.sh
# write REMOTE_DIR/.infisical.env (machine identity), confirm Infisical prod secrets, then:
SERVER=ubuntu@NEW_HOST ACS_IMAGE_TAG=<sha> ./scripts/bootstrap-server.sh --start
```

CI: [`.github/workflows/deploy.yml`](../.github/workflows/deploy.yml) builds/pushes the image and runs `deploy.sh --resume` against the GitHub Environment’s `DEPLOY_HOST`. Add Environment secrets (`DEPLOY_HOST`, `DEPLOY_USER`, `SSH_PRIVATE_KEY`, `DOCKERHUB_*`) per server/stage.

| Aspect | Value |
|--------|-------|
| Compose | `docker-compose.multitenant.yml` |
| Caddy | `Caddyfile.multitenant` |
| Env template | `.env.multitenant` |
| Image | `naharemete/steward_acs:${ACS_IMAGE_TAG:-multitenant}` |
| DB | Neon Postgres via `DATABASE_URL` (optional local Postgres override) |
| Memory | Obsidian vaults under `/vaults` |
| Auth | API/developer keys for services; Auth0 OIDC for individual dashboard users and human MCP access |
| Syncthing admin | **Not** on public HTTPS — SSH tunnel to `127.0.0.1:8384` |
| Email (optional) | Set `RESEND_API_KEY` + `RESEND_FROM_EMAIL` for invitation email; omit to keep copy-link only |

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

Keep `SELF_SERVICE_ORGS_ENABLED=false` until imports, owner bootstrap, wildcard DNS/TLS, and Auth0 callback settings are verified. New invitations email when Resend is configured (`RESEND_API_KEY` + `RESEND_FROM_EMAIL`); otherwise they expose a single-use link to the administrator. Only the token hash is stored.

### Axiom observability

Production can export inbound HTTP/Phoenix/Ecto traces and structured application logs to Axiom. Create an **Events** dataset in Axiom once, then set these values in the untracked production `.env`:

```bash
AXIOM_LOGS=xaat-your-ingest-token
AXIOM_DATASET=steward-acs
# AXIOM_DOMAIN=https://api.axiom.co  # only needed for an Axiom edge deployment
```

Export is enabled only when the release runs in `prod` and `AXIOM_LOGS` is non-empty. Development and test never ship telemetry, even when a local `.env` contains the token. Keep the token ingest-scoped to the configured dataset.

After deploying, request `/mcp/health`, exercise a database-backed route, and confirm both traces and log events arrive in the dataset. HTTP query-string values are redacted from spans. BEAM memory and scheduler utilization ship every 30s as `message == "vm.metrics"` events (not a separate OTLP metrics dataset).

### Secrets

Local: untracked `.env`. Multi-tenant prod: Infisical via `scripts/infisical-compose.sh` (thin host `.env` is non-secret config only). See [`guides/secrets.md`](secrets.md).

Archived older compose files: [`archive/deploy/`](../archive/deploy/).
