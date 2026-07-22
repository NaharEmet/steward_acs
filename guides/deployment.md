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
# optional: set LLM keys, ACS_PASSWORD
docker compose up -d
# or: mix phx.server  (loads .env via config/runtime.exs)
```

- Compose: [`docker-compose.yml`](../docker-compose.yml)
- DB: SQLite
- URL: `http://localhost:4001`

## Multi-tenant production (canonical)

```bash
cp .env.multitenant .env
# fill SECRET_KEY_BASE, MCP_API_KEY, ACS_PASSWORD, Syncthing keys, Auth0 as needed
# set ACS_ORG_DASHBOARD_CREDS for non-default org dashboard logins
docker compose -f docker-compose.multitenant.yml up -d
```

Or deploy from a workstation with an immutable Git-SHA tag:

```bash
SERVER=ubuntu@YOUR_HOST ./scripts/deploy.sh
SERVER=ubuntu@YOUR_HOST ./scripts/status.sh
SERVER=ubuntu@YOUR_HOST ./scripts/backup-prod.sh
```

| Aspect | Value |
|--------|-------|
| Compose | `docker-compose.multitenant.yml` |
| Caddy | `Caddyfile.multitenant` |
| Env template | `.env.multitenant` |
| Image | `naharemete/steward_acs:${ACS_IMAGE_TAG:-multitenant}` |
| DB (default) | SQLite at `/data/steward.sqlite` |
| Memory | Obsidian vaults under `/vaults` |
| Auth | API key + optional Auth0 OAuth; dashboard basic auth (+ per-org JSON) |
| Syncthing admin | **Not** on public HTTPS — SSH tunnel to `127.0.0.1:8384` |

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

### Axiom observability

Production can export inbound HTTP/Phoenix/Ecto traces and structured application logs to Axiom. Create an **Events** dataset in Axiom once, then set these values in the untracked production `.env`:

```bash
AXIOM_LOGS=xaat-your-ingest-token
AXIOM_DATASET=steward-acs
# AXIOM_DOMAIN=https://api.axiom.co  # only needed for an Axiom edge deployment
```

Export is enabled only when the release runs in `prod` and `AXIOM_LOGS` is non-empty. Development and test never ship telemetry, even when a local `.env` contains the token. Keep the token ingest-scoped to the configured dataset.

After deploying, request `/mcp/health`, exercise a database-backed route, and confirm both traces and log events arrive in the dataset. HTTP query-string values are redacted from spans; metrics are not exported.

### Secrets

Use `pass` / untracked `.env` only. Never commit Axiom or Auth0 tokens. See [`guides/secrets.md`](secrets.md).

Archived older compose files: [`archive/deploy/`](../archive/deploy/).
