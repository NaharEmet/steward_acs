#!/bin/sh
set -e

# Postgres/Neon: DATABASE_URL only. SQLite: DATABASE_PATH.
# Never default to /data/steward.sqlite when DATABASE_PATH is unset —
# that kept migrations on the volume while Neon stayed empty.
if [ -n "${DATABASE_PATH:-}" ]; then
  DATA_DIR=$(dirname "$DATABASE_PATH")
  mkdir -p "$DATA_DIR"
  chown acs:acs "$DATA_DIR"
elif [ -n "${DATABASE_URL:-}" ]; then
  mkdir -p /data
  chown acs:acs /data
else
  echo "ERROR: set DATABASE_URL (Neon/Postgres) or DATABASE_PATH (SQLite)" >&2
  exit 1
fi

# Named Docker volumes start root-owned; the release runs as acs (uid 1000).
# If /vaults stays root:root 755, skill_save / specs_propose mkdir_p fails —
# Elixir often surfaces that as :enoent rather than :eacces.
OBSIDIAN_VAULT_PATH="${OBSIDIAN_VAULT_PATH:-}"
if [ -n "$OBSIDIAN_VAULT_PATH" ]; then
  mkdir -p "${OBSIDIAN_VAULT_PATH}/orgs" \
    "${OBSIDIAN_VAULT_PATH}/private/memories"
  chown -R acs:acs "$OBSIDIAN_VAULT_PATH"
fi

if [ -f /app/bin/steward_acs ]; then
  if [ -n "${DATABASE_URL:-}" ]; then
    adapter=$(su-exec acs /app/bin/steward_acs eval 'IO.write(inspect(Acs.Repo.__adapter__()))')
    echo "[entrypoint] repo_adapter=${adapter}"
    case "$adapter" in
      *Postgres*) ;;
      *)
        echo "ERROR: DATABASE_URL set but image compiled with ${adapter}" >&2
        echo "ERROR: rebuild with --build-arg REPO_ADAPTER=postgres --no-cache" >&2
        exit 1
        ;;
    esac
  fi

  echo "[entrypoint] Running database migrations..."
  su-exec acs /app/bin/steward_acs eval "Acs.Release.migrate"
  echo "[entrypoint] Starting steward_acs release..."
  exec su-exec acs /app/bin/steward_acs start
fi

exec "$@"
