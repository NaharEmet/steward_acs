#!/usr/bin/env bash
# Read-only deployment status. Never prints secret values.
set -euo pipefail

SERVER="${SERVER:-}"
REMOTE_DIR="${REMOTE_DIR:-/home/ubuntu/steward_acs}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.multitenant.yml}"

# Keys we expect in prod .env (presence only). Optional keys reported separately.
REQUIRED_ENV_KEYS=(
  SECRET_KEY_BASE
  MCP_API_KEY
  ACS_IMAGE_TAG
  MCP_PUBLIC_URL
)
OPTIONAL_ENV_KEYS=(
  ACS_IMAGE_TAG_PREV
  OAUTH_FIXED_DCR_CLIENT_ID
  OAUTH_BEARER_ENABLED
  OIDC_BROWSER_ENABLED
  AUTH0_DOMAIN
  AUTH0_WEB_CLIENT_ID
  ACCOUNT_HOST
  ACS_ORG_DASHBOARD_CREDS
)

print_local() {
  echo "=== local ==="
  echo "git_sha=$(git rev-parse --short=12 HEAD 2>/dev/null || echo n/a)"
  echo "branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo n/a)"
  if [[ -n "$(git status --porcelain 2>/dev/null || true)" ]]; then
    echo "tree=dirty"
  else
    echo "tree=clean"
  fi
  echo "compose=${COMPOSE_FILE}"
  if [[ -f .env ]]; then
    echo "env_mode=$(stat -c '%a' .env 2>/dev/null || stat -f '%Lp' .env)"
    echo "env_keys=$(grep -E '^[A-Z0-9_]+=' .env | cut -d= -f1 | paste -sd, -)"
  else
    echo "env=missing"
  fi
}

print_remote() {
  # Pass key lists as NUL-safe comma strings into remote bash.
  local req_csv opt_csv
  req_csv=$(IFS=,; echo "${REQUIRED_ENV_KEYS[*]}")
  opt_csv=$(IFS=,; echo "${OPTIONAL_ENV_KEYS[*]}")

  echo "=== remote (${SERVER}) ==="
  # shellcheck disable=SC2029
  ssh "${SERVER}" bash -s -- "$REMOTE_DIR" "$COMPOSE_FILE" "$req_csv" "$opt_csv" <<'REMOTE'
set -euo pipefail
REMOTE_DIR="$1"
COMPOSE_FILE="$2"
REQ_CSV="$3"
OPT_CSV="$4"
cd "$REMOTE_DIR"

echo "compose_file=${COMPOSE_FILE}"
if [[ -f "$COMPOSE_FILE" ]]; then echo compose_present=yes; else echo compose_present=no; fi
echo "env_mode=$(stat -c '%a' .env 2>/dev/null || echo n/a)"

env_has() {
  local key="$1"
  [[ -f .env ]] && grep -qE "^${key}=." .env 2>/dev/null
}

IFS=',' read -r -a REQ <<< "$REQ_CSV"
missing=()
for key in "${REQ[@]}"; do
  if env_has "$key"; then
    echo "env_has_${key}=yes"
  else
    echo "env_has_${key}=no"
    missing+=("$key")
  fi
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "env_required_missing=${missing[*]}"
else
  echo "env_required_missing="
fi

IFS=',' read -r -a OPT <<< "$OPT_CSV"
for key in "${OPT[@]}"; do
  if env_has "$key"; then
    echo "env_has_${key}=yes"
  else
    echo "env_has_${key}=no"
  fi
done

# Compose wires OAUTH_FIXED only if the key appears in the yml (presence of wiring).
if [[ -f "$COMPOSE_FILE" ]] && grep -q 'OAUTH_FIXED_DCR_CLIENT_ID' "$COMPOSE_FILE" 2>/dev/null; then
  echo "compose_wires_oauth_fixed_dcr=yes"
else
  echo "compose_wires_oauth_fixed_dcr=no"
fi

docker inspect -f 'image_id={{.Image}} image_ref={{.Config.Image}} health={{.State.Health.Status}} started={{.State.StartedAt}}' steward_acs 2>/dev/null || echo steward_acs=missing
rev=$(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' steward_acs 2>/dev/null || true)
dirty=$(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.dirty"}}' steward_acs 2>/dev/null || true)
echo "image_git_sha=${rev:-n/a}"
echo "image_dirty=${dirty:-n/a}"

docker exec steward_acs sh -c 'if [ -n "$DATABASE_PATH" ]; then echo db_backend=sqlite path_set=yes; elif [ -n "$DATABASE_URL" ]; then echo db_backend=postgres url_set=yes; else echo db_backend=unknown; fi' 2>/dev/null || true
docker exec steward_acs sh -c 'printf %s "$MULTI_TENANT"' 2>/dev/null | xargs -I{} echo multi_tenant={}
docker exec steward_acs sh -c 'printf %s "$ACS_ORG_NAME"' 2>/dev/null | xargs -I{} echo acs_org_name={}

ls -1dt /home/ubuntu/steward_backups/*/ 2>/dev/null | head -1 | xargs -I{} echo latest_backup={}
if latest=$(ls -1dt /home/ubuntu/steward_backups/*/ 2>/dev/null | head -1); then
  if [[ -f ${latest}steward.online.sqlite ]]; then
    echo "backup_db_mtime=$(stat -c '%y' ${latest}steward.online.sqlite)"
  fi
fi
REMOTE
}

print_local
if [[ -n "$SERVER" ]]; then
  print_remote
else
  echo "=== remote ==="
  echo "set SERVER=ubuntu@host to include remote status"
fi
