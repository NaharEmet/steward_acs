# Archived deployment configs

Superseded by `docker-compose.multitenant.yml` (+ optional `docker-compose.postgres.yml` override).

| File | Former use |
|------|------------|
| `docker-compose.cloudflare.yml` | Cloudflare origin cert + Syncthing multitenant stack |
| `docker-compose.remote.yml` | Postgres + Caddy single-domain remote deploy |

Production deploy:

```bash
cp .env.multitenant .env
docker compose -f docker-compose.multitenant.yml up -d
```
