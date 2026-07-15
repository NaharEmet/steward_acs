---
audit_reasoning: "The skill provides clear, actionable steps for daily operations and first-time setup using pass. It includes verification (list secrets) and failure recovery (rotate credentials if leaked). The description is distinct from the name and content opening. It is unique compared to existing skills, which focus on deployment, installation, and Auth0 users, not secrets management."
audit_score: 8
audit_status: "ok"
audited_at: "2026-07-15T14:43:57.812210Z"
description: Managing secrets with pass (password-store)
name: "secrets"
scope_paths: ["guides/secrets", "guides/deployment", "config"]
when_to_use: Before touching .env, deploying, or storing credentials — never commit secrets to git
tags: ["secrets", "pass", "deploy"]
---

# Secrets Management

Manage secrets with `pass` (password-store) — don't edit `.env` directly.

## Daily ops (SSH into the server)

```bash
# Set/update a secret
pass insert steward/SECRET_KEY_BASE

# Read a secret
pass show steward/SECRET_KEY_BASE

# List all secrets
pass ls steward/

# Regenerate .env from pass store
./scripts/secrets-env.sh -w .env
```

Regenerate `.env` after any change, then `docker compose up -d`.

## First-time setup

```bash
# Install pass (one-time)
sudo apt install pass    # Debian/Ubuntu
brew install pass        # macOS

# Generate a GPG key (one-time)
gpg --full-generate-key

# Initialize for this project
pass init <YOUR_GPG_KEY_ID>
mkdir -p ~/.password-store/steward
pass insert steward/SECRET_KEY_BASE
```

The container doesn't need `pass` — it receives env vars from Docker as before.

## Never commit live credentials

Tracked templates (`.env.example`, `.env.multitenant`, `.env.remote`) must keep Auth0 / DB / API secrets empty. If a Management API secret ever lands in git history, rotate it in Auth0 immediately and scrub the file.
