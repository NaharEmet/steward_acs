#!/usr/bin/env bash
# Read-only deployment status. Never prints secret values.
set -euo pipefail

SERVER="${SERVER:-}"
REMOTE_DIR="${REMOTE_DIR:-/home/ubuntu/steward_acs}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.multitenant.yml}"

# Keys we expect after Infisical inject (presence only). Optional keys reported separately.
# Thin .env holds non-secrets; .env.infisical holds secrets from last compose inject.
REQUIRED_ENV_KEYS=(
  SECRET_KEY_BASE
  MCP_API_KEY
  DATABASE_URL
  ACS_IMAGE_TAG
  MCP_PUBLIC_URL
)
OPTIONAL_ENV_KEYS=(
  ACS_IMAGE_TAG_PREV
  ACS_ACTIVE_SLOT
  CADDY_BUNDLE_HASH
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
echo "infisical_agent=$(test -f .infisical.env && echo yes || echo no)"
echo "infisical_secrets_file=$(test -f .env.infisical && echo yes || echo no)"
echo "infisical_compose=$(test -x scripts/infisical-compose.sh && echo yes || echo no)"

env_has() {
  local key="$1"
  # Prefer injected secrets file, then thin .env (non-secrets like ACS_IMAGE_TAG / MCP_PUBLIC_URL).
  if [[ -f .env.infisical ]] && grep -qE "^${key}=." .env.infisical 2>/dev/null; then
    return 0
  fi
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

# Infisical --env-file alone does not inject into the container; keys must be listed under environment:.
if [[ -f "$COMPOSE_FILE" ]] && grep -q 'NIM_API_KEY' "$COMPOSE_FILE" 2>/dev/null; then
  echo "compose_wires_nim_api_key=yes"
else
  echo "compose_wires_nim_api_key=no"
fi

# Resolve active ACS container (blue/green). Fall back to legacy steward_acs.
ACTIVE_SLOT=""
if [[ -f .env ]]; then
  ACTIVE_SLOT=$(grep -E '^ACS_ACTIVE_SLOT=' .env 2>/dev/null | tail -1 | cut -d= -f2- || true)
fi
ACS_CTR=""
case "$ACTIVE_SLOT" in
  blue|green) ACS_CTR="steward_acs_${ACTIVE_SLOT}" ;;
esac
if [[ -z "$ACS_CTR" ]] || ! docker inspect "$ACS_CTR" >/dev/null 2>&1; then
  if docker inspect steward_acs_blue >/dev/null 2>&1 && \
     [[ "$(docker inspect -f '{{.State.Running}}' steward_acs_blue 2>/dev/null || echo false)" == true ]]; then
    ACS_CTR=steward_acs_blue
    ACTIVE_SLOT=blue
  elif docker inspect steward_acs_green >/dev/null 2>&1 && \
       [[ "$(docker inspect -f '{{.State.Running}}' steward_acs_green 2>/dev/null || echo false)" == true ]]; then
    ACS_CTR=steward_acs_green
    ACTIVE_SLOT=green
  elif docker inspect steward_acs >/dev/null 2>&1; then
    ACS_CTR=steward_acs
    ACTIVE_SLOT=legacy
  fi
fi
echo "acs_active_slot=${ACTIVE_SLOT:-unknown}"
echo "acs_container=${ACS_CTR:-missing}"

if [[ -n "${ACS_CTR:-}" ]]; then
  docker inspect -f 'image_id={{.Image}} image_ref={{.Config.Image}} health={{.State.Health.Status}} started={{.State.StartedAt}}' "$ACS_CTR" 2>/dev/null || echo "${ACS_CTR}=missing"
  rev=$(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$ACS_CTR" 2>/dev/null || true)
  dirty=$(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.dirty"}}' "$ACS_CTR" 2>/dev/null || true)
  echo "image_git_sha=${rev:-n/a}"
  echo "image_dirty=${dirty:-n/a}"

  docker exec "$ACS_CTR" sh -c 'if [ -n "$DATABASE_PATH" ]; then echo db_backend=sqlite path_set=yes; elif [ -n "$DATABASE_URL" ]; then echo db_backend=postgres url_set=yes; else echo db_backend=unknown; fi' 2>/dev/null || true
  docker exec "$ACS_CTR" sh -c 'printf %s "$MULTI_TENANT"' 2>/dev/null | xargs -I{} echo multi_tenant={}
  docker exec "$ACS_CTR" sh -c 'printf %s "$ACS_ORG_NAME"' 2>/dev/null | xargs -I{} echo acs_org_name={}
else
  echo "steward_acs=missing"
  echo "image_git_sha=n/a"
  echo "image_dirty=n/a"
fi

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
