#!/usr/bin/env bash
# Read-only deployment status. Never prints secret values.
set -euo pipefail

SERVER="${SERVER:-}"
REMOTE_DIR="${REMOTE_DIR:-/home/ubuntu/steward_acs}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.multitenant.yml}"

print_local() {
  echo "=== local ==="
  echo "git_sha=$(git rev-parse --short=12 HEAD 2>/dev/null || echo n/a)"
  echo "branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo n/a)"
  echo "compose=${COMPOSE_FILE}"
  if [[ -f .env ]]; then
    echo "env_mode=$(stat -c '%a' .env 2>/dev/null || stat -f '%Lp' .env)"
    echo "env_keys=$(grep -E '^[A-Z0-9_]+=' .env | cut -d= -f1 | paste -sd, -)"
  else
    echo "env=missing"
  fi
}

print_remote() {
  echo "=== remote (${SERVER}) ==="
  ssh "${SERVER}" "set -e
    cd '${REMOTE_DIR}'
    echo compose_file='${COMPOSE_FILE}'
    if [[ -f '${COMPOSE_FILE}' ]]; then echo compose_present=yes; else echo compose_present=no; fi
    echo env_mode=\$(stat -c '%a' .env 2>/dev/null || echo n/a)
    echo env_has_org_creds=\$(grep -c '^ACS_ORG_DASHBOARD_CREDS=' .env 2>/dev/null || echo 0)
    docker inspect -f 'image_id={{.Image}} image_ref={{.Config.Image}} health={{.State.Health.Status}} started={{.State.StartedAt}}' steward_acs 2>/dev/null || echo steward_acs=missing
    labels=\$(docker inspect -f '{{index .Config.Labels \"org.opencontainers.image.revision\"}}' steward_acs 2>/dev/null || true)
    echo image_git_sha=\${labels:-n/a}
    # DB backend hint from env inside container (no secret values)
    docker exec steward_acs sh -c 'if [ -n \"\$DATABASE_PATH\" ]; then echo db_backend=sqlite path_set=yes; elif [ -n \"\$DATABASE_URL\" ]; then echo db_backend=postgres url_set=yes; else echo db_backend=unknown; fi' 2>/dev/null || true
    docker exec steward_acs sh -c 'printf %s \"\$MULTI_TENANT\"' 2>/dev/null | xargs -I{} echo multi_tenant={}
    docker exec steward_acs sh -c 'printf %s \"\$ACS_ORG_NAME\"' 2>/dev/null | xargs -I{} echo acs_org_name={}
    ls -1dt /home/ubuntu/steward_backups/*/ 2>/dev/null | head -1 | xargs -I{} echo latest_backup={}
    if latest=\$(ls -1dt /home/ubuntu/steward_backups/*/ 2>/dev/null | head -1); then
      if [[ -f \${latest}steward.online.sqlite ]]; then
        echo backup_db_mtime=\$(stat -c '%y' \${latest}steward.online.sqlite)
      fi
    fi
  "
}

print_local
if [[ -n "$SERVER" ]]; then
  print_remote
else
  echo "=== remote ==="
  echo "set SERVER=ubuntu@host to include remote status"
fi
