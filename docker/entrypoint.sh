#!/bin/sh
set -e

if [ -f /app/bin/steward_acs ]; then
  echo "[entrypoint] Running database migrations..."
  /app/bin/steward_acs eval "Acs.Release.migrate"
  echo "[entrypoint] Starting steward_acs release..."
  exec /app/bin/steward_acs start
fi

exec "$@"
