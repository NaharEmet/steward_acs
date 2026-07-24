#!/usr/bin/env bash
# First-time multi-tenant host setup. Idempotent — safe to re-run.
#
# Usage:
#   SERVER=ubuntu@NEW_HOST ./scripts/bootstrap-server.sh
#   SERVER=ubuntu@NEW_HOST ENV_FILE=./.env.prod ./scripts/bootstrap-server.sh
#   SERVER=ubuntu@NEW_HOST ACS_IMAGE_TAG=abc123 ./scripts/bootstrap-server.sh --start
#
# After bootstrap: fill .env on the server (or pass ENV_FILE), then --start
# or run: SERVER=… ACS_IMAGE_TAG=… ./scripts/deploy.sh --resume
set -euo pipefail

SERVER="${SERVER:-}"
REMOTE_DIR="${REMOTE_DIR:-/home/ubuntu/steward_acs}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.multitenant.yml}"
CADDY_FILE="${CADDY_FILE:-Caddyfile.multitenant}"
ENV_FILE="${ENV_FILE:-}"
ACS_IMAGE_TAG="${ACS_IMAGE_TAG:-multitenant}"
START=0

for arg in "$@"; do
  case "$arg" in
    --start) START=1 ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *)
      echo "ERROR: unknown arg: $arg" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$SERVER" ]]; then
  echo "ERROR: SERVER must be set (e.g. SERVER=ubuntu@203.0.113.10)" >&2
  exit 1
fi

info() { echo "[bootstrap] $*"; }

info "Installing Docker Engine + Compose plugin on ${SERVER} (noop if present)"
ssh "${SERVER}" 'bash -s' <<'REMOTE'
set -euo pipefail
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sudo sh
  sudo usermod -aG docker "$USER" || true
fi
docker version >/dev/null
docker compose version >/dev/null
REMOTE

info "Creating ${REMOTE_DIR} and syncing compose bundle"
ssh "${SERVER}" "mkdir -p '${REMOTE_DIR}/priv' '${REMOTE_DIR}/certs'"
scp "${COMPOSE_FILE}" "${CADDY_FILE}" "${SERVER}:${REMOTE_DIR}/"
if [[ -f docker-compose.postgres.yml ]]; then
  scp docker-compose.postgres.yml "${SERVER}:${REMOTE_DIR}/"
fi
if [[ -f priv/orgs.yaml ]]; then
  scp priv/orgs.yaml "${SERVER}:${REMOTE_DIR}/priv/orgs.yaml"
fi

if [[ -n "$ENV_FILE" ]]; then
  [[ -f "$ENV_FILE" ]] || { echo "ERROR: ENV_FILE not found: $ENV_FILE" >&2; exit 1; }
  info "Uploading ENV_FILE → ${REMOTE_DIR}/.env (mode 600)"
  scp "$ENV_FILE" "${SERVER}:${REMOTE_DIR}/.env"
  ssh "${SERVER}" "chmod 600 '${REMOTE_DIR}/.env'"
elif ssh "${SERVER}" "test -f '${REMOTE_DIR}/.env'"; then
  info "Remote .env already present — leaving it"
else
  info "Seeding .env from .env.multitenant template (fill secrets before --start)"
  scp .env.multitenant "${SERVER}:${REMOTE_DIR}/.env"
  ssh "${SERVER}" "chmod 600 '${REMOTE_DIR}/.env'"
fi

# Pin image tag for first pull
ssh "${SERVER}" "cd '${REMOTE_DIR}' &&
  if grep -q '^ACS_IMAGE_TAG=' .env 2>/dev/null; then
    sed -i 's/^ACS_IMAGE_TAG=.*/ACS_IMAGE_TAG=${ACS_IMAGE_TAG}/' .env
  else
    echo 'ACS_IMAGE_TAG=${ACS_IMAGE_TAG}' >> .env
  fi"

info "Bootstrap files ready on ${SERVER}:${REMOTE_DIR}"
info "Next: edit .env (SECRET_KEY_BASE, MCP_API_KEY, Auth0, MCP_PUBLIC_URL), open 80/443, DNS → host"

if [[ "$START" -eq 1 ]]; then
  info "Starting stack with ACS_IMAGE_TAG=${ACS_IMAGE_TAG}"
  SERVER="${SERVER}" REMOTE_DIR="${REMOTE_DIR}" ACS_IMAGE_TAG="${ACS_IMAGE_TAG}" \
    ./scripts/deploy.sh --resume
else
  info "When .env is filled: SERVER=${SERVER} ACS_IMAGE_TAG=${ACS_IMAGE_TAG} ./scripts/bootstrap-server.sh --start"
  info "Or ongoing updates: SERVER=${SERVER} ./scripts/deploy.sh"
fi
