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
