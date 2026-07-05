#!/bin/sh
set -e

# Ensure the data directory exists and is writable by the acs user
DATA_DIR="${DATABASE_PATH:-/data/steward.sqlite}"
DATA_DIR=$(dirname "$DATA_DIR")
if [ ! -d "$DATA_DIR" ]; then
  mkdir -p "$DATA_DIR"
fi
chown acs:acs "$DATA_DIR"

# Ensure the Obsidian vault private/memories directory exists and is writable
OBSIDIAN_VAULT_PATH="${OBSIDIAN_VAULT_PATH:-}"
if [ -n "$OBSIDIAN_VAULT_PATH" ] && [ -d "$OBSIDIAN_VAULT_PATH" ]; then
  memories_dir="${OBSIDIAN_VAULT_PATH}/private/memories"
  mkdir -p "$memories_dir"
  chown -R acs:acs "$memories_dir"
fi

if [ -f /app/bin/steward_acs ]; then
  echo "[entrypoint] Running database migrations..."
  su-exec acs /app/bin/steward_acs eval "Acs.Release.migrate"
  echo "[entrypoint] Starting steward_acs release..."
  exec su-exec acs /app/bin/steward_acs start
fi

exec "$@"
