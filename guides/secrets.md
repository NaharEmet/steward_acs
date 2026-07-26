# Secrets Management

Canonical skill: [`priv/skills/secrets.md`](../priv/skills/secrets.md).

| Environment | Source |
|-------------|--------|
| Local | Untracked `.env` (from `.env.example`) |
| Multi-tenant prod | Infisical `steward_prod` / `prod` via `scripts/infisical-compose.sh` |

Quick rules:

- Local: edit `.env` only. Never put Neon / prod Auth0 secrets there.
- Prod: secrets in Infisical; thin host `.env` is non-secret config (see `.env.multitenant`).
- Machine identity for the host: `.infisical.env` (mode 600). Cursor Infisical MCP: gitignored `.cursor/mcp.json`.
- Optional Infisical keys may stay `REPLACE_ME` / blank — inject skips them.
- Never commit credentials. Auth0 M2M for ops scripts (`certs/Oauth.md`) is not ACS runtime.
- After any leaked secret, rotate in the provider.
- Prod image/cutover: GitHub Actions (Infisical inject happens on the host during `deploy.sh --resume`).
