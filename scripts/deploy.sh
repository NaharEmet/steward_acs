#!/usr/bin/env bash
# Deterministic deploy: build once, tag by Git SHA, push, cut over in one SSH.
#
# Usage:
#   SERVER=ubuntu@HOST ./scripts/deploy.sh              # full build+push+cutover
#   ./scripts/deploy.sh --push-only                     # build+push only (CI)
#   SERVER=ubuntu@HOST ./scripts/deploy.sh --resume     # cutover only (image already pushed)
#   SERVER=ubuntu@HOST ./scripts/deploy.sh --rollback   # pin previous tag and cut over
#
# Env:
#   ALLOW_DIRTY=1   allow dirty tree (forces unique tag + --no-cache)
#   SKIP_SMOKE=1    skip public health / optional DCR smoke
#   PUBLIC_URL=     override smoke base URL (default: MCP_PUBLIC_URL from remote .env)
set -euo pipefail

REGISTRY="${REGISTRY:-naharemete/steward_acs}"
SERVER="${SERVER:-}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.multitenant.yml}"
CADDY_FILE="${CADDY_FILE:-Caddyfile.multitenant}"
REMOTE_DIR="${REMOTE_DIR:-/home/ubuntu/steward_acs}"
MODE="deploy"
ALLOW_DIRTY="${ALLOW_DIRTY:-0}"
SKIP_SMOKE="${SKIP_SMOKE:-0}"

for arg in "$@"; do
  case "$arg" in
    --push-only) MODE="push-only" ;;
    --resume) MODE="resume" ;;
    --rollback) MODE="rollback" ;;
    -h|--help)
      sed -n '2,14p' "$0"
      exit 0
      ;;
    *)
      echo "ERROR: unknown arg: $arg (use --push-only, --resume, --rollback, or --help)" >&2
      exit 1
      ;;
  esac
done

if [[ "$MODE" != "push-only" && -z "$SERVER" ]]; then
  echo "ERROR: SERVER must be set (e.g. SERVER=ubuntu@139.99.172.4)" >&2
  exit 1
fi

info() { echo "[deploy] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

DIRTY=0
if [[ -n "$(git status --porcelain 2>/dev/null || true)" ]]; then
  DIRTY=1
fi

GIT_SHA="${GIT_SHA:-$(git rev-parse --short=12 HEAD)}"
DIRTY_FLAG="clean"

case "$MODE" in
  deploy|push-only)
    if [[ "$DIRTY" -eq 1 && "$ALLOW_DIRTY" != "1" ]]; then
      die "refusing dirty working tree (commit first, or ALLOW_DIRTY=1 for a one-off hotfix)"
    fi
    if [[ "$DIRTY" -eq 1 ]]; then
      DIRTY_FLAG="dirty"
      ACS_IMAGE_TAG="${ACS_IMAGE_TAG:-${GIT_SHA}-dirty-$(date -u +%Y%m%d%H%M%S)}"
      BUILD_NO_CACHE=(--no-cache)
      info "ALLOW_DIRTY=1: tagging ${ACS_IMAGE_TAG} and building with --no-cache"
    else
      ACS_IMAGE_TAG="${ACS_IMAGE_TAG:-$GIT_SHA}"
      BUILD_NO_CACHE=()
    fi
    ;;
  resume|rollback)
    ACS_IMAGE_TAG="${ACS_IMAGE_TAG:-}"
    ;;
esac

COMPOSE_ARGS=(-f "${COMPOSE_FILE}")
if [[ "${WITH_POSTGRES:-false}" == "true" ]]; then
  COMPOSE_ARGS+=(-f docker-compose.postgres.yml)
fi
COMPOSE_ARGS_STR="${COMPOSE_ARGS[*]}"

# --- build + push (deploy / push-only) ---
if [[ "$MODE" == "deploy" || "$MODE" == "push-only" ]]; then
  info "Building ${REGISTRY}:${ACS_IMAGE_TAG} (git=${GIT_SHA} dirty=${DIRTY_FLAG})"
  docker build \
    "${BUILD_NO_CACHE[@]}" \
    --target release \
    --build-arg REPO_ADAPTER=sqlite \
    --build-arg GIT_SHA="${GIT_SHA}" \
    --build-arg GIT_DIRTY="${DIRTY_FLAG}" \
    --build-arg SECRET_KEY_BASE="${SECRET_KEY_BASE:-build_time_secret_key_base_not_used_at_runtime}" \
    -t "${REGISTRY}:${ACS_IMAGE_TAG}" \
    -t "${REGISTRY}:multitenant" \
    .

  info "Pushing ${REGISTRY}:${ACS_IMAGE_TAG} and :multitenant"
  docker push "${REGISTRY}:${ACS_IMAGE_TAG}"
  docker push "${REGISTRY}:multitenant"

  if [[ "$MODE" == "push-only" ]]; then
    info "push-only done tag=${ACS_IMAGE_TAG}"
    echo "ACS_IMAGE_TAG=${ACS_IMAGE_TAG}"
    exit 0
  fi
fi

# --- sync compose/caddy (deploy + resume; rollback keeps remote compose) ---
if [[ "$MODE" != "rollback" ]]; then
  info "Syncing compose/caddy bundle to ${SERVER}:${REMOTE_DIR}"
  ssh "${SERVER}" "mkdir -p '${REMOTE_DIR}/priv'"
  scp "${COMPOSE_FILE}" "${CADDY_FILE}" "${SERVER}:${REMOTE_DIR}/"
  if [[ -f docker-compose.postgres.yml ]]; then
    scp docker-compose.postgres.yml "${SERVER}:${REMOTE_DIR}/"
  fi
  if [[ -f priv/orgs.yaml ]]; then
    scp priv/orgs.yaml "${SERVER}:${REMOTE_DIR}/priv/orgs.yaml"
  fi
fi

# --- single remote cutover (pull/up/caddy/health) ---
# shellcheck disable=SC2029
CUTOVER=$(ssh "${SERVER}" bash -s -- \
  "$MODE" "$REMOTE_DIR" "$COMPOSE_FILE" "$COMPOSE_ARGS_STR" "${ACS_IMAGE_TAG:-}" <<'REMOTE'
set -euo pipefail
MODE="$1"
REMOTE_DIR="$2"
COMPOSE_FILE="$3"
# intentionally unquoted split of compose args from laptop
COMPOSE_ARGS_STR="$4"
ACS_IMAGE_TAG="${5:-}"

cd "$REMOTE_DIR"
# shellcheck disable=SC2206
COMPOSE_ARGS=($COMPOSE_ARGS_STR)

env_get() {
  local key="$1"
  [[ -f .env ]] || return 1
  grep -E "^${key}=" .env 2>/dev/null | tail -1 | cut -d= -f2- || true
}

env_set() {
  local key="$1" val="$2"
  touch .env
  if grep -q "^${key}=" .env 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" .env
  else
    echo "${key}=${val}" >> .env
  fi
}

current_tag="$(env_get ACS_IMAGE_TAG || true)"
prev_tag="$(env_get ACS_IMAGE_TAG_PREV || true)"

case "$MODE" in
  rollback)
    [[ -n "$prev_tag" ]] || { echo "ERROR: ACS_IMAGE_TAG_PREV missing; nothing to roll back to" >&2; exit 1; }
    ACS_IMAGE_TAG="$prev_tag"
    echo "[remote] rollback to ACS_IMAGE_TAG=${ACS_IMAGE_TAG} (was ${current_tag:-none})"
    ;;
  resume)
    if [[ -z "$ACS_IMAGE_TAG" ]]; then
      ACS_IMAGE_TAG="$current_tag"
    fi
    [[ -n "$ACS_IMAGE_TAG" ]] || { echo "ERROR: no ACS_IMAGE_TAG for --resume (set ACS_IMAGE_TAG= or pin .env)" >&2; exit 1; }
    echo "[remote] resume cutover ACS_IMAGE_TAG=${ACS_IMAGE_TAG}"
    ;;
  deploy)
    [[ -n "$ACS_IMAGE_TAG" ]] || { echo "ERROR: ACS_IMAGE_TAG empty" >&2; exit 1; }
    echo "[remote] deploy cutover ACS_IMAGE_TAG=${ACS_IMAGE_TAG}"
    ;;
esac

# Remember previous pin before overwriting (skip if same tag).
if [[ -n "${current_tag:-}" && "$current_tag" != "$ACS_IMAGE_TAG" ]]; then
  env_set ACS_IMAGE_TAG_PREV "$current_tag"
fi
env_set ACS_IMAGE_TAG "$ACS_IMAGE_TAG"

echo "[remote] preflight compose config"
ACS_IMAGE_TAG="$ACS_IMAGE_TAG" docker compose "${COMPOSE_ARGS[@]}" config >/dev/null

echo "[remote] pull steward_acs"
ACS_IMAGE_TAG="$ACS_IMAGE_TAG" docker compose "${COMPOSE_ARGS[@]}" pull steward_acs

echo "[remote] up steward_acs"
ACS_IMAGE_TAG="$ACS_IMAGE_TAG" docker compose "${COMPOSE_ARGS[@]}" up -d --no-build --remove-orphans steward_acs

echo "[remote] recreate caddy"
ACS_IMAGE_TAG="$ACS_IMAGE_TAG" docker compose "${COMPOSE_ARGS[@]}" up -d --no-build --force-recreate caddy

# Seed org registry into the data volume when missing.
if ! docker exec steward_acs sh -c 'test -s /data/orgs.yaml' 2>/dev/null; then
  if [[ -f priv/orgs.yaml ]]; then
    docker cp priv/orgs.yaml steward_acs:/data/orgs.yaml || true
  fi
fi

echo "[remote] waiting for healthy"
STATUS=starting
for _ in $(seq 1 40); do
  STATUS=$(docker inspect -f '{{.State.Health.Status}}' steward_acs 2>/dev/null || echo starting)
  [[ "$STATUS" == "healthy" ]] && break
  sleep 2
done

DIGEST=$(docker inspect -f '{{.Image}}' steward_acs)
REV=$(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' steward_acs 2>/dev/null || true)
DIRTY_L=$(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.dirty"}}' steward_acs 2>/dev/null || true)
PUBLIC_URL=$(env_get MCP_PUBLIC_URL || true)
FIXED_DCR=$(env_get OAUTH_FIXED_DCR_CLIENT_ID || true)

echo "REMOTE_DIGEST=${DIGEST}"
echo "REMOTE_HEALTH=${STATUS}"
echo "REMOTE_TAG=${ACS_IMAGE_TAG}"
echo "REMOTE_REV=${REV:-n/a}"
echo "REMOTE_DIRTY=${DIRTY_L:-n/a}"
echo "REMOTE_PUBLIC_URL=${PUBLIC_URL:-}"
echo "REMOTE_FIXED_DCR_SET=$([ -n "${FIXED_DCR:-}" ] && echo yes || echo no)"
echo "REMOTE_FIXED_DCR_ID=${FIXED_DCR:-}"

[[ "$STATUS" == "healthy" ]] || { echo "ERROR: container not healthy (${STATUS})" >&2; exit 1; }
REMOTE
)

info "cutover output:"
echo "$CUTOVER"

REMOTE_HEALTH=$(echo "$CUTOVER" | awk -F= '/^REMOTE_HEALTH=/{print $2; exit}')
REMOTE_TAG=$(echo "$CUTOVER" | awk -F= '/^REMOTE_TAG=/{print $2; exit}')
REMOTE_PUBLIC_URL=$(echo "$CUTOVER" | awk -F= '/^REMOTE_PUBLIC_URL=/{print $2; exit}')
REMOTE_FIXED_DCR_SET=$(echo "$CUTOVER" | awk -F= '/^REMOTE_FIXED_DCR_SET=/{print $2; exit}')
REMOTE_FIXED_DCR_ID=$(echo "$CUTOVER" | awk -F= '/^REMOTE_FIXED_DCR_ID=/{print $2; exit}')
REMOTE_REV=$(echo "$CUTOVER" | awk -F= '/^REMOTE_REV=/{print $2; exit}')

[[ "$REMOTE_HEALTH" == "healthy" ]] || die "cutover reported unhealthy"

# --- smoke (public) ---
if [[ "$SKIP_SMOKE" == "1" ]]; then
  info "SKIP_SMOKE=1 — skipping public smoke checks"
else
  PUBLIC_URL="${PUBLIC_URL:-$REMOTE_PUBLIC_URL}"
  PUBLIC_URL="${PUBLIC_URL%/}"
  [[ -n "$PUBLIC_URL" ]] || die "no PUBLIC_URL / MCP_PUBLIC_URL for smoke (set PUBLIC_URL=https://…)"

  info "smoke GET ${PUBLIC_URL}/mcp/health"
  curl -fsS --max-time 20 "${PUBLIC_URL}/mcp/health" >/dev/null

  if [[ "$REMOTE_FIXED_DCR_SET" == "yes" && -n "${REMOTE_FIXED_DCR_ID}" ]]; then
    info "smoke POST ${PUBLIC_URL}/oidc/register (expect fixed client)"
    got=$(curl -fsS --max-time 30 -X POST "${PUBLIC_URL}/oidc/register" \
      -H 'content-type: application/json' \
      -d '{"client_name":"deploy-smoke","redirect_uris":["https://claude.ai/api/mcp/auth_callback"]}' \
      | python3 -c 'import sys,json; print(json.load(sys.stdin).get("client_id",""))')
    if [[ "$got" != "$REMOTE_FIXED_DCR_ID" ]]; then
      die "DCR smoke failed: got client_id=${got:-empty} want ${REMOTE_FIXED_DCR_ID} (Caddy must not proxy /oidc/register to Auth0; compose must pass OAUTH_FIXED_DCR_CLIENT_ID)"
    fi
    info "DCR smoke ok (fixed client)"
  else
    info "OAUTH_FIXED_DCR_CLIENT_ID unset on server — skipping DCR smoke"
  fi
fi

info "Deployed tag=${REMOTE_TAG} rev=${REMOTE_REV} health=${REMOTE_HEALTH}"
info "Rollback: SERVER=${SERVER} ./scripts/deploy.sh --rollback"
info "Resume:   SERVER=${SERVER} ACS_IMAGE_TAG=${REMOTE_TAG} ./scripts/deploy.sh --resume"
