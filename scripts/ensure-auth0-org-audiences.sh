#!/usr/bin/env bash
# Ensure Auth0 resource servers + third-party grants exist for each org MCP URL.
# Usage: BASE_DOMAIN=stewardacs.xyz ./scripts/ensure-auth0-org-audiences.sh
set -euo pipefail

DOMAIN="${AUTH0_DOMAIN:-dev-jw5wgp2b.us.auth0.com}"
BASE_DOMAIN="${BASE_DOMAIN:-stewardacs.xyz}"
ORGS_FILE="${ORGS_FILE:-priv/orgs.yaml}"
M2M_ID="${AUTH0_MGMT_CLIENT_ID:-${AUTH0_M2M_CLIENT_ID:-}}"
M2M_SECRET="${AUTH0_MGMT_CLIENT_SECRET:-${AUTH0_M2M_CLIENT_SECRET:-}}"
MGMT_AUDIENCE="https://${DOMAIN}/api/v2/"

[[ -n "$M2M_ID" && -n "$M2M_SECRET" ]] || { echo "Set AUTH0_MGMT_CLIENT_ID/SECRET" >&2; exit 1; }
[[ -f "$ORGS_FILE" ]] || { echo "Missing $ORGS_FILE" >&2; exit 1; }

api() {
  curl -sS --fail-with-body -X "$1" "https://${DOMAIN}/api/v2$2" \
    -H "authorization: Bearer ${MGMT_TOKEN}" \
    -H "content-type: application/json" \
    "${@:3}"
}

MGMT_TOKEN=$(curl -sS --fail-with-body -X POST "https://${DOMAIN}/oauth/token" \
  -H "content-type: application/json" \
  -d "{\"client_id\":\"${M2M_ID}\",\"client_secret\":\"${M2M_SECRET}\",\"audience\":\"${MGMT_AUDIENCE}\",\"grant_type\":\"client_credentials\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

while read -r AUDIENCE; do
  echo "[auth0] ensuring API ${AUDIENCE}"
  MCP_API_ID=$(api GET /resource-servers | python3 -c "
import sys, json
aud = sys.argv[1]
for rs in json.load(sys.stdin):
    if rs.get('identifier') == aud:
        print(rs['id']); break
" "$AUDIENCE")

  if [[ -z "$MCP_API_ID" ]]; then
    MCP_API_ID=$(api POST /resource-servers -d "{
      \"name\": \"Steward ACS MCP (${AUDIENCE})\",
      \"identifier\": \"${AUDIENCE}\",
      \"signing_alg\": \"RS256\",
      \"token_lifetime\": 86400,
      \"scopes\": [{\"value\": \"mcp:tools\", \"description\": \"Call Steward ACS MCP tools\"}]
    }" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
    echo "  created id=${MCP_API_ID}"
  else
    echo "  exists id=${MCP_API_ID}"
  fi

  api PATCH "/resource-servers/${MCP_API_ID}" -d '{
    "enforce_policies": true,
    "token_dialect": "access_token_authz"
  }' >/dev/null

  ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${AUDIENCE}'))")
  HAS_DEFAULT=$(api GET "/client-grants?audience=${ENCODED}" | python3 -c "
import sys, json
aud = sys.argv[1]
for g in json.load(sys.stdin):
    if g.get('default_for') == 'third_party_clients' and g.get('audience') == aud:
        print('yes'); break
else:
    print('no')
" "$AUDIENCE")

  if [[ "$HAS_DEFAULT" != "yes" ]]; then
    api POST /client-grants -d "{
      \"default_for\": \"third_party_clients\",
      \"audience\": \"${AUDIENCE}\",
      \"scope\": [\"mcp:tools\"],
      \"subject_type\": \"user\"
    }" >/dev/null
    echo "  added third-party grant"
  fi
done < <(python3 - "$ORGS_FILE" "$BASE_DOMAIN" <<'PY'
import sys
import yaml

orgs_file, base = sys.argv[1], sys.argv[2]
with open(orgs_file) as f:
    orgs = yaml.safe_load(f).get("orgs", {})
for slug in orgs:
    print(f"https://{slug}.{base}/mcp/sse")
PY
)

echo "Done."
