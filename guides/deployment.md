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

### Org identity and URLs

The authenticated credential owns the request org:

- dashboard sessions use `users.org` (one user, one org),
- developer keys use the key's `org`, and
- OAuth tokens use `https://stewardacs.xyz/org`.

Org subdomains are optional convenience hints. Neutral/apex URLs work; a known
org URL is accepted only when its hint matches the authenticated credential.
Do not rely on hostnames as tenant authorization.

`ACS_ORG_DASHBOARD_CREDS` maps credentials to the user org created at login; it
is login provisioning, not the tenancy model.

### Clean-cut rebuild and re-provision

This auth rewrite intentionally has no incremental tenant-data migration.
Before deploying it, stop writes and dump the current SQLite/Postgres database
for rollback/audit. Use `SERVER=ubuntu@YOUR_HOST ./scripts/backup-prod.sh` for
the canonical deployment, then verify the timestamped backup artifact before
removing/replacing the app DB volume. For manual recovery snapshots, use
`sqlite3 /data/steward.sqlite '.backup /backup/steward-pre-org-rewrite.sqlite'`
or `pg_dump "$DATABASE_URL" > steward-pre-org-rewrite.sql` as appropriate.
Preserve the vault YAML and org registry, then start with a fresh app database.
Boot runs `Acs.Memory.Indexer.sync_all`, rebuilding derived
knowledge indexes from YAML; tasks, locks, sessions, developer keys, dashboard
users, and other coordination state start empty.

Preserve:

- memory/spec/skill YAML under the configured vault paths,
- `priv/orgs.yaml` or the mounted `/data/orgs.yaml`, and
- Auth0 tenant users if desired (their org metadata must still be checked).

Re-provision after the fresh boot:

1. Seed or edit `ORGS_FILE` (`/data/orgs.yaml`).
2. Set `ACS_USERNAME` / `ACS_PASSWORD` and per-org dashboard credentials.
3. Sign in once per dashboard org to recreate its `admin@localhost` user row.
4. Generate new developer keys for each org (`generate_key` or dashboard).
5. Re-create or re-stamp Auth0 users with their single org claim.
6. Update clients with the new keys and a neutral URL, or a matching org URL.
7. Verify YAML memories were indexed and keep the old DB dump until validation completes.

### Org registry

`ORGS_FILE=/data/orgs.yaml` (volume). Seed from `priv/orgs.yaml` once if the volume copy is missing:

```bash
docker cp priv/orgs.yaml steward_acs:/data/orgs.yaml
```

### Secrets

Use `pass` / untracked `.env` only. Never commit Auth0 M2M secrets. See [`guides/secrets.md`](secrets.md).

Archived older compose files: [`archive/deploy/`](../archive/deploy/).
