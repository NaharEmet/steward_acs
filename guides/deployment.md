# Deployment Styles

ACS supports two deployment styles depending on your use case.

## Code Development

Lightweight setup for individual developers coordinating with AI agents. Agents manage tasks, memories, and files on your local project.

| Aspect | Config |
|--------|--------|
| Compose file | `docker-compose.yml` |
| Database | SQLite (file-based, no extra container) |
| Memory store | YAML files in `priv/acs_memory/` |
| Auth | API key (`MCP_API_KEY`) + dashboard basic auth |
| Network | Localhost only, port 4001 |
| TLS | None |

```bash
docker compose up -d
```

Memories are machine-readable YAML — agents use them for context. No human-facing knowledge tooling.

## Org Memory

Production setup for organizational knowledge management. Memories live in an Obsidian vault that humans edit directly and sync via Syncthing.

| Aspect | Config |
|--------|--------|
| Compose file | `docker-compose.remote.yml` or `docker-compose.cloudflare.yml` |
| Database | PostgreSQL (`remote.yml`) or SQLite (`cloudflare.yml`) |
| Memory store | Obsidian vault (`MEMORY_STORE=obsidian`) |
| Auth | API key + optional Auth0 OAuth |
| Network | Public domain with TLS (Caddy) |
| Sync | Syncthing — local Obsidian ↔ server vault |

Agents write memories as markdown files with YAML frontmatter. Humans open the same vault in Obsidian. Both see the same knowledge.

```bash
cp .env.remote .env
# Fill in: SECRET_KEY_BASE, MCP_API_KEY, DB_PASSWORD, ACS_PASSWORD
# Set MEMORY_STORE=obsidian, OBSIDIAN_VAULT_PATH=/obsidian
docker compose -f docker-compose.remote.yml up -d --build
```

## Which one to use

| You want... | Use |
|-------------|-----|
| Agent coordination on a dev project | Code Development |
| Persistent org knowledge, human-readable | Org Memory |
| Multiple orgs on one server (subdomain isolation) | Multi-Tenant (see below) |
| Both at the same time | Run Code Development locally, Org Memory on a server. They're independent instances. |

## Multi-Tenant (Subdomain)

Production setup for hosting multiple orgs on one ACS instance. Each org gets its own subdomain for ACS and Obsidian/Syncthing. All data is scoped by org in the database, ETS cache, and filesystem.

| Aspect | Config |
|--------|--------|
| Compose file | `docker-compose.multitenant.yml` (generic) or `docker-compose.cloudflare.yml` (prod) |
| Env template | `.env.multitenant` |
| Caddy config | `Caddyfile.multitenant` or `Caddyfile` |
| Database | SQLite (single DB, `org` column isolates rows) |
| Memory store | Configured org at `/vaults/private/memories/`; additional orgs under `/vaults/orgs/<org>/private/memories/` |
| Auth | API key + optional Auth0 OAuth (scoped to subdomain) |
| Network | `https://<org>.<BASE_DOMAIN>` and `https://<org>.obsidian.<BASE_DOMAIN>` |
| Sync | One Syncthing container per org (separate API key + config volume) |

### URLs

| Service | Pattern | Example |
|---------|---------|---------|
| ACS (dashboard + MCP) | `<org>.<BASE_DOMAIN>` | `prod.stewardacs.xyz` |
| Obsidian / Syncthing | `<org>.obsidian.<BASE_DOMAIN>` | `prod.obsidian.stewardacs.xyz` |
| Legacy apex Obsidian | `obsidian.<BASE_DOMAIN>` | routes to `syncthing_default` |

### Required environment variables

Copy the template and fill in secrets:

```bash
cp .env.multitenant .env
# Edit: SECRET_KEY_BASE, MCP_API_KEY, ACS_PASSWORD, Syncthing API keys
docker compose -f docker-compose.multitenant.yml up -d --build
```

For the Cloudflare/prod stack (`docker-compose.cloudflare.yml`):

```bash
cp .env.multitenant .env
# Also set AUTH0_* vars if using OAuth
docker compose -f docker-compose.cloudflare.yml up -d --build
```

| Variable | Required | Description |
|----------|----------|-------------|
| `MULTI_TENANT` | yes | Set to `true` (baked into compose files) |
| `ACS_ORG_NAME` | yes | Existing/configured org that keeps legacy memory paths and IDs |
| `BASE_DOMAIN` | yes | Root domain, e.g. `stewardacs.xyz` |
| `SECRET_KEY_BASE` | yes | Phoenix secret |
| `MCP_API_KEY` | yes | MCP API key |
| `ACS_PASSWORD` | yes | Dashboard password |
| `SYNCTHING_DEFAULT_API_KEY` | yes | API key for `syncthing_default` |
| `SYNCTHING_PROD_API_KEY` | yes (prod) | API key for `syncthing_prod` |
| `SYNCTHING_FSGBHUTAN_API_KEY` | yes (if org exists) | API key for `syncthing_fsgbhutan` |
| `SYNCTHING_SAFETYCONNECT_API_KEY` | yes (if org exists) | API key for `syncthing_safetyconnect` |
| `SYNC_BCRYPT_PASS` | optional | Basic auth for legacy `obsidian.<BASE_DOMAIN>` |

Generate Syncthing API keys in each container's GUI (Settings → API) after first boot, or set random strings before deploy and configure via env (`STGUIAPIKEY`).

### Database migration

Run the included migration before serving traffic:

```bash
docker compose -f docker-compose.multitenant.yml run --rm acs mix ecto.migrate
```

The configured `ACS_ORG_NAME` keeps existing memory paths and unqualified index/vector IDs. Additional orgs use `orgs/<org>/...` paths and tenant-qualified derived-store IDs.

### Org definitions

`priv/orgs.yaml` provides the bundled seed registry with `default`, `prod`, `fsgbhutan`, and `safetyconnect`.
Remote compose files set `ORGS_FILE=/data/orgs.yaml`; `create_org` writes that persistent copy, which survives image and DB replacement.

### Vault layout

```
/vaults/
├── private/memories/          # configured ACS_ORG_NAME (legacy path)
└── orgs/
    ├── acme/private/memories/
    └── beta/private/memories/
```

Syncthing containers share the `vaults` volume but each has its own config volume. Point the configured org at `/var/syncthing/vaults/`; point additional orgs at `/var/syncthing/vaults/orgs/<org>/`.

### Provisioning a new org

1. Call the `create_org` admin MCP tool (creates vault directories + updates the persistent `ORGS_FILE` registry).
2. Add a `syncthing_<subdomain>` service to the compose file with its own `STGUIAPIKEY` and config volume.
3. Add a Caddy route: `<subdomain>.obsidian.<BASE_DOMAIN>` → `http://syncthing_<subdomain>:8384`.
4. Add the new `SYNCTHING_<SUBDOMAIN>_API_KEY` to `.env`.
5. Redeploy Caddy + the new Syncthing container.

The `create_org` response includes the exact URLs and a reminder about Syncthing/Caddy steps.

### Default orgs

`priv/orgs.yaml` ships with `default`, `prod`, `fsgbhutan`, and `safetyconnect`. The generic multi-tenant stack includes Syncthing services and routes for these orgs; add equivalent services/routes to other stacks as needed.
