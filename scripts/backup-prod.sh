#!/usr/bin/env bash
# Backup prod vaults (+ orgs.yaml when present). Neon holds the DB — use Neon PITR / exports for SQL.
# Legacy SQLite files are copied when still present on the volume. Never prints secrets.
set -euo pipefail

SERVER="${SERVER:?Set SERVER=ubuntu@host}"
REMOTE_DIR="${REMOTE_DIR:-/home/ubuntu/steward_acs}"

ssh "${SERVER}" 'set -euo pipefail
TS=$(date -u +%Y%m%dT%H%M%SZ)
BK=/home/ubuntu/steward_backups/$TS
mkdir -p "$BK"
REMOTE_DIR="'"${REMOTE_DIR}"'"
cd "$REMOTE_DIR" 2>/dev/null || true
ACTIVE_SLOT=""
if [[ -f .env ]]; then
  ACTIVE_SLOT=$(grep -E "^ACS_ACTIVE_SLOT=" .env 2>/dev/null | tail -1 | cut -d= -f2- || true)
fi
ACS_CTR=""
case "$ACTIVE_SLOT" in
  blue|green) ACS_CTR="steward_acs_${ACTIVE_SLOT}" ;;
esac
for candidate in "$ACS_CTR" steward_acs_blue steward_acs_green steward_acs; do
  [[ -n "$candidate" ]] || continue
  if docker inspect "$candidate" >/dev/null 2>&1; then
    ACS_CTR="$candidate"
    break
  fi
done
echo "acs_container=${ACS_CTR:-missing}" > "$BK/containers.txt"
docker inspect -f "{{.Name}} {{.Image}} {{.Config.Image}}" ${ACS_CTR:-} steward_caddy 2>/dev/null >> "$BK/containers.txt" || true

# Optional legacy SQLite (pre-Neon). Neon backups are via Neon console / PITR.
if [[ -n "${ACS_CTR:-}" ]] && docker exec "$ACS_CTR" test -f /data/steward.sqlite 2>/dev/null; then
  docker cp "$ACS_CTR:/data/steward.sqlite" "$BK/steward.sqlite" || true
  docker run --rm -v steward_acs_acs_data:/data -v "$BK":/out alpine:3.22 \
    sh -c "apk add --no-cache sqlite >/dev/null && sqlite3 /data/steward.sqlite \".backup /out/steward.online.sqlite\"" || true
  chmod 600 "$BK"/steward*.sqlite 2>/dev/null || true
fi

docker run --rm -v steward_acs_vaults:/vaults:ro -v "$BK":/out alpine:3.22 \
  tar czf /out/vaults.tar.gz -C /vaults .
# orgs.yaml may be a bind mount into the container
if [[ -n "${ACS_CTR:-}" ]] && docker exec "$ACS_CTR" test -f /data/orgs.yaml; then
  docker cp "$ACS_CTR:/data/orgs.yaml" "$BK/orgs.yaml"
elif [[ -n "${ACS_CTR:-}" ]] && docker exec "$ACS_CTR" test -f /app/priv/orgs.yaml; then
  docker cp "$ACS_CTR:/app/priv/orgs.yaml" "$BK/orgs.yaml"
elif [[ -f '"${REMOTE_DIR}"'/orgs.yaml ]]; then
  cp "'"${REMOTE_DIR}"'/orgs.yaml" "$BK/orgs.yaml"
fi
ls -lah "$BK"
echo "BACKUP_DIR=$BK"
echo "NOTE=DB is Neon — use Neon PITR/export for SQL backups"
'
