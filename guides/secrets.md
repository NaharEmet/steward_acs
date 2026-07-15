# Secrets Management

Canonical skill: [`priv/skills/secrets.md`](../priv/skills/secrets.md).

Quick rules:

- Manage secrets with `pass`; regenerate `.env` via `./scripts/secrets-env.sh -w .env`.
- Never commit Auth0 M2M / Management API credentials. `.env.remote` and `.env.multitenant` are templates with empty placeholders only.
- After rotating any secret that was ever committed, revoke the old credential in its provider (Auth0 dashboard → Applications → M2M → rotate).
- `chmod 600 .env` on every host.
