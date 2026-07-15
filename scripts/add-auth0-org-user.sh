#!/usr/bin/env bash
# Add or update an Auth0 user for a specific ACS org (passwordless email).
#
# Required env:
#   AUTH0_M2M_CLIENT_ID / AUTH0_M2M_CLIENT_SECRET  (or AUTH0_MGMT_CLIENT_ID / AUTH0_MGMT_CLIENT_SECRET)
#   AUTH0_USER_EMAIL
#   AUTH0_USER_ORG          org slug, e.g. safetyconnect
#
# Optional:
#   AUTH0_USER_NAME         display name (default: local part of email)
#   AUTH0_USER_ROLE         app_metadata role (default: collaborator)
#   AUTH0_DOMAIN            default: dev-jw5wgp2b.us.auth0.com
#   AUTH0_DB_CONNECTION     default: email
#
set -euo pipefail

DOMAIN="${AUTH0_DOMAIN:-dev-jw5wgp2b.us.auth0.com}"
MGMT_AUDIENCE="https://${DOMAIN}/api/v2/"
DB_CONNECTION="${AUTH0_DB_CONNECTION:-email}"
ORG_CLAIM="https://stewardacs.xyz/org"
M2M_ID="${AUTH0_MGMT_CLIENT_ID:-${AUTH0_M2M_CLIENT_ID:-}}"
M2M_SECRET="${AUTH0_MGMT_CLIENT_SECRET:-${AUTH0_M2M_CLIENT_SECRET:-}}"
EMAIL="${AUTH0_USER_EMAIL:?Set AUTH0_USER_EMAIL}"
ORG="${AUTH0_USER_ORG:?Set AUTH0_USER_ORG}"
NAME="${AUTH0_USER_NAME:-${EMAIL%%@*}}"
ROLE="${AUTH0_USER_ROLE:-collaborator}"

[[ -n "$M2M_ID" && -n "$M2M_SECRET" ]] || { echo "Set AUTH0_MGMT_CLIENT_ID and AUTH0_MGMT_CLIENT_SECRET" >&2; exit 1; }

api() {
  local method="$1" path="$2"
  shift 2
  curl -sS --fail-with-body -X "$method" \
    "https://${DOMAIN}/api/v2${path}" \
    -H "authorization: Bearer ${MGMT_TOKEN}" \
    -H "content-type: application/json" \
    "$@"
}

MGMT_TOKEN=$(curl -sS --fail-with-body -X POST "https://${DOMAIN}/oauth/token" \
  -H "content-type: application/json" \
  -d "{\"client_id\":\"${M2M_ID}\",\"client_secret\":\"${M2M_SECRET}\",\"audience\":\"${MGMT_AUDIENCE}\",\"grant_type\":\"client_credentials\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

ROLE_ID=$(api GET "/roles?name_filter=MCP%20User" | python3 -c "
import sys, json
for r in json.load(sys.stdin):
    if r.get('name') == 'MCP User':
        print(r['id']); break
")

USER_JSON=$(api POST /users -d "{
  \"email\": \"${EMAIL}\",
  \"name\": \"${NAME}\",
  \"connection\": \"${DB_CONNECTION}\",
  \"email_verified\": true,
  \"app_metadata\": {\"org\": \"${ORG}\", \"role\": \"${ROLE}\"}
}" 2>/dev/null || true)

USER_ID=$(echo "$USER_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('user_id',''))" 2>/dev/null || true)

if [[ -z "$USER_ID" ]]; then
  USER_ID=$(api GET "/users-by-email?email=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${EMAIL}'))")" \
    | python3 -c "import sys,json; u=json.load(sys.stdin); print(u[0]['user_id'] if u else '')")
  api PATCH "/users/${USER_ID}" -d "{\"app_metadata\":{\"org\":\"${ORG}\",\"role\":\"${ROLE}\"},\"name\":\"${NAME}\"}" >/dev/null
  echo "Updated existing user ${EMAIL} -> org=${ORG}"
else
  echo "Created user ${EMAIL} -> org=${ORG}"
fi

[[ -n "$ROLE_ID" ]] && api POST "/users/${USER_ID}/roles" -d "{\"roles\":[\"${ROLE_ID}\"]}" >/dev/null 2>&1 || true
echo "Assigned MCP User role (if role exists)"

# Ensure post-login action copies app_metadata.org into access token
ACTION_CODE="exports.onExecutePostLogin = async (event, api) => {
  const org = event.user.app_metadata && event.user.app_metadata.org;
  if (org) api.accessToken.setCustomClaim('${ORG_CLAIM}', org);
};"

ACTION_ID=$(api GET "/actions/actions?triggerId=post-login" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for a in d.get('actions', []):
    if a.get('name') == 'ACS org claim':
        print(a['id']); break
" || true)

if [[ -z "$ACTION_ID" ]]; then
  ACTION_ID=$(api POST /actions/actions -d "$(python3 -c "
import json
print(json.dumps({
  'name': 'ACS org claim',
  'code': '''${ACTION_CODE}''',
  'runtime': 'node22',
  'supported_triggers': [{'id': 'post-login', 'version': 'v3'}],
}))
")" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
fi

api POST "/actions/actions/${ACTION_ID}/deploy" -d "{}" >/dev/null 2>&1 || true
api PATCH /actions/triggers/post-login/bindings -d "{\"bindings\":[{\"ref\":{\"type\":\"action_id\",\"value\":\"${ACTION_ID}\"},\"display_name\":\"ACS org claim\"}]}" >/dev/null 2>&1 || true

echo "Done: ${EMAIL} is in org ${ORG} (user_id=${USER_ID})"
echo "Connector URL: https://${ORG}.stewardacs.xyz/mcp/sse"
