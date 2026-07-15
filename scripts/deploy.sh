#!/usr/bin/env bash
# Deterministic deploy: build once, tag by Git SHA, push, pull that exact tag on the server.
set -euo pipefail

REGISTRY="${REGISTRY:-naharemete/steward_acs}"
SERVER="${SERVER:-}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.multitenant.yml}"
CADDY_FILE="${CADDY_FILE:-Caddyfile.multitenant}"
GIT_SHA="${GIT_SHA:-$(git rev-parse --short=12 HEAD)}"
ACS_IMAGE_TAG="${ACS_IMAGE_TAG:-$GIT_SHA}"
REMOTE_DIR="${REMOTE_DIR:-/home/ubuntu/steward_acs}"

if [[ -z "$SERVER" ]]; then
  echo "ERROR: SERVER must be set (e.g. SERVER=ubuntu@139.99.172.4)" >&2
  exit 1
fi

info() { echo "[deploy] $*"; }

info "Building ${REGISTRY}:${ACS_IMAGE_TAG} (git=${GIT_SHA})"
docker build \
  --target release \
  --build-arg REPO_ADAPTER=sqlite \
  --build-arg GIT_SHA="${GIT_SHA}" \
  --build-arg SECRET_KEY_BASE="${SECRET_KEY_BASE:-build_time_secret_key_base_not_used_at_runtime}" \
  -t "${REGISTRY}:${ACS_IMAGE_TAG}" \
  -t "${REGISTRY}:multitenant" \
  .

info "Pushing ${REGISTRY}:${ACS_IMAGE_TAG} and :multitenant"
docker push "${REGISTRY}:${ACS_IMAGE_TAG}"
docker push "${REGISTRY}:multitenant"

info "Syncing compose/caddy bundle to ${SERVER}:${REMOTE_DIR}"
ssh "${SERVER}" "mkdir -p '${REMOTE_DIR}'"
scp "${COMPOSE_FILE}" "${CADDY_FILE}" "${SERVER}:${REMOTE_DIR}/"
if [[ -f docker-compose.postgres.yml ]]; then
  scp docker-compose.postgres.yml "${SERVER}:${REMOTE_DIR}/"
fi
if [[ -f priv/orgs.yaml ]]; then
  ssh "${SERVER}" "mkdir -p '${REMOTE_DIR}/priv'"
  scp priv/orgs.yaml "${SERVER}:${REMOTE_DIR}/priv/orgs.yaml"
fi

COMPOSE_ARGS=(-f "${COMPOSE_FILE}")
if [[ "${WITH_POSTGRES:-false}" == "true" ]]; then
  COMPOSE_ARGS+=(-f docker-compose.postgres.yml)
fi

info "Preflight compose config on server"
ssh "${SERVER}" "cd '${REMOTE_DIR}' && ACS_IMAGE_TAG='${ACS_IMAGE_TAG}' docker compose ${COMPOSE_ARGS[*]} config >/dev/null"

info "Pull + recreate steward_acs (+ caddy if present)"
ssh "${SERVER}" "cd '${REMOTE_DIR}' && ACS_IMAGE_TAG='${ACS_IMAGE_TAG}' docker compose ${COMPOSE_ARGS[*]} pull steward_acs && ACS_IMAGE_TAG='${ACS_IMAGE_TAG}' docker compose ${COMPOSE_ARGS[*]} up -d --no-build --remove-orphans steward_acs caddy"

# Seed org registry into the data volume when missing (prod historically used a bind mount).
ssh "${SERVER}" "docker exec steward_acs sh -c 'test -s /data/orgs.yaml' || docker cp '${REMOTE_DIR}/priv/orgs.yaml' steward_acs:/data/orgs.yaml 2>/dev/null || true"

info "Waiting for health"
for _ in $(seq 1 40); do
  if ssh "${SERVER}" 'docker inspect -f "{{.State.Health.Status}}" steward_acs 2>/dev/null' | grep -qx healthy; then
    break
  fi
  sleep 2
done

DIGEST=$(ssh "${SERVER}" 'docker inspect -f "{{.Image}}" steward_acs')
STATUS=$(ssh "${SERVER}" 'docker inspect -f "{{.State.Health.Status}}" steward_acs')
info "Deployed digest=${DIGEST} health=${STATUS} tag=${ACS_IMAGE_TAG}"
[[ "$STATUS" == "healthy" ]] || { echo "ERROR: container not healthy" >&2; exit 1; }
