---
audit_reasoning: All checks passed
audit_score: 10
audit_status: ok
audited_at: 2026-07-05T11:19:22.725162Z
description: Managing secrets with pass (password-store)
name: secrets
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
