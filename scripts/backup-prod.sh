#!/usr/bin/env bash
# Backup live prod SQLite + vaults (+ orgs.yaml when present). Never prints secrets.
set -euo pipefail

SERVER="${SERVER:?Set SERVER=ubuntu@host}"
REMOTE_DIR="${REMOTE_DIR:-/home/ubuntu/steward_acs}"

ssh "${SERVER}" 'set -euo pipefail
TS=$(date -u +%Y%m%dT%H%M%SZ)
BK=/home/ubuntu/steward_backups/$TS
mkdir -p "$BK"
docker inspect -f "{{.Name}} {{.Image}} {{.Config.Image}}" steward_acs steward_caddy 2>/dev/null > "$BK/containers.txt" || true
docker cp steward_acs:/data/steward.sqlite "$BK/steward.sqlite"
docker run --rm -v steward_acs_acs_data:/data -v "$BK":/out alpine:3.22 \
  sh -c "apk add --no-cache sqlite >/dev/null && sqlite3 /data/steward.sqlite \".backup /out/steward.online.sqlite\""
docker run --rm -v steward_acs_vaults:/vaults:ro -v "$BK":/out alpine:3.22 \
  tar czf /out/vaults.tar.gz -C /vaults .
# orgs.yaml may be a bind mount into the container
if docker exec steward_acs test -f /data/orgs.yaml; then
  docker cp steward_acs:/data/orgs.yaml "$BK/orgs.yaml"
elif docker exec steward_acs test -f /app/priv/orgs.yaml; then
  docker cp steward_acs:/app/priv/orgs.yaml "$BK/orgs.yaml"
elif [[ -f '"${REMOTE_DIR}"'/orgs.yaml ]]; then
  cp "'"${REMOTE_DIR}"'/orgs.yaml" "$BK/orgs.yaml"
fi
chmod 600 "$BK"/steward*.sqlite 2>/dev/null || true
ls -lah "$BK"
echo "BACKUP_DIR=$BK"
'
