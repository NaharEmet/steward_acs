#!/bin/bash
set -euo pipefail

# ─── Config ───────────────────────────────────────────────────────────────────
REGISTRY="naharemete/steward_acs"
TAG="cloudflare-$(date +%s)"
SERVER="ubuntu@139.99.172.4"
DOMAIN="${DOMAIN:-prod.stewardacs.xyz}"
COMPOSE_FILE="docker-compose.cloudflare.yml"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[deploy]${NC} $1"; }
ok()    { echo -e "${GREEN}[✓]${NC} $1"; }
fail()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# ─── 1. Build ─────────────────────────────────────────────────────────────────
info "Building image: ${REGISTRY}:${TAG}"
SECRET_KEY_BASE="${SECRET_KEY_BASE:-$(mix phx.gen.secret 2>/dev/null || openssl rand -base64 48)}"
docker build \
  --target release \
  --build-arg REPO_ADAPTER=sqlite \
  --build-arg SECRET_KEY_BASE="${SECRET_KEY_BASE}" \
  -t "${REGISTRY}:${TAG}" \
  -t "${REGISTRY}:latest" \
  .
ok "Build complete"

# ─── 2. Push ──────────────────────────────────────────────────────────────────
info "Pushing to registry"
docker push "${REGISTRY}:${TAG}"
docker push "${REGISTRY}:latest"
ok "Push complete"

# ─── 3. Deploy ────────────────────────────────────────────────────────────────
info "Copying compose file to server"
ssh "${SERVER}" "mkdir -p ~/steward_acs"
scp "${COMPOSE_FILE}" "${SERVER}:~/steward_acs/"
scp Caddyfile "${SERVER}:~/steward_acs/"
ok "Files copied"

info "Deploying on server"
ssh "${SERVER}" "cd ~/steward_acs && \
  DOMAIN='${DOMAIN}' \
  ACS_URL='http://steward_acs:4001' \
  docker compose -f ${COMPOSE_FILE} pull && \
  docker compose -f ${COMPOSE_FILE} up -d --remove-orphans"
ok "Deployed ${REGISTRY}:${TAG} to ${SERVER}"

info "Done! https://${DOMAIN}"
