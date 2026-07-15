#!/usr/bin/env bash
# Configure Auth0 tenant for Claude MCP Connectors (Steward ACS).
#
# Required env:
#   AUTH0_M2M_CLIENT_ID      Machine-to-Machine app client ID
#   AUTH0_M2M_CLIENT_SECRET  Machine-to-Machine app client secret
#
# Optional env:
#   AUTH0_DOMAIN               default: dev-jw5wgp2b.us.auth0.com
#   AUTH0_AUDIENCE             default: https://prod.stewardacs.xyz/mcp/sse
#   AUTH0_USER_EMAIL           create this user if set (passwordless email connection)
#   AUTH0_USER_PASSWORD        ignored for passwordless; only used if AUTH0_DB_CONNECTION is a DB conn
#   AUTH0_DB_CONNECTION        default: email (passwordless OTP via New Universal Login)
#   SKIP_CLAUDE_APP            set to 1 to skip manual Claude OAuth app creation
#
# Login model (Claude Connectors):
#   New Universal Login + Identifier First + passwordless email OTP.
#   Caddy injects connection=email on /authorize. True Auth0 "magic links"
#   require Classic Login and are not used here.
#
set -euo pipefail

DOMAIN="${AUTH0_DOMAIN:-dev-jw5wgp2b.us.auth0.com}"
AUDIENCE="${AUTH0_AUDIENCE:-https://prod.stewardacs.xyz/mcp/sse}"
MGMT_AUDIENCE="https://${DOMAIN}/api/v2/"
DB_CONNECTION="${AUTH0_DB_CONNECTION:-email}"
CLAUDE_CALLBACK="https://claude.ai/api/mcp/auth_callback"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[auth0]${NC} $*"; }
ok()    { echo -e "${GREEN}[ok]${NC} $*"; }
fail()  { echo -e "${RED}[fail]${NC} $*" >&2; exit 1; }

# Optional: read M2M creds from certs/Oauth.md
if [[ -f certs/Oauth.md ]]; then
  if [[ -z "${AUTH0_M2M_CLIENT_ID:-}" ]]; then
    AUTH0_M2M_CLIENT_ID=$(python3 -c "import re; t=open('certs/Oauth.md').read(); m=re.search(r'\"client_id\":\"([^\"]+)\"', t); print(m.group(1) if m else '')")
  fi
  if [[ -z "${AUTH0_M2M_CLIENT_SECRET:-}" ]]; then
    AUTH0_M2M_CLIENT_SECRET=$(python3 -c "import re; t=open('certs/Oauth.md').read(); m=re.search(r'\"client_secret\":\"([^\"]+)\"', t); print(m.group(1) if m else '')")
  fi
fi

[[ -n "${AUTH0_M2M_CLIENT_ID:-}" ]] || fail "Set AUTH0_M2M_CLIENT_ID (or add to certs/Oauth.md)"
[[ -n "${AUTH0_M2M_CLIENT_SECRET:-}" ]] || fail "Set AUTH0_M2M_CLIENT_SECRET (or add to certs/Oauth.md)"

api() {
  local method="$1" path="$2"
  shift 2
  curl -sS --fail-with-body -X "$method" \
    "https://${DOMAIN}/api/v2${path}" \
    -H "authorization: Bearer ${MGMT_TOKEN}" \
    -H "content-type: application/json" \
    "$@"
}

info "Fetching Management API token..."
TOKEN_RESP=$(curl -sS --fail-with-body -X POST "https://${DOMAIN}/oauth/token" \
  -H "content-type: application/json" \
  -d "{
    \"client_id\": \"${AUTH0_M2M_CLIENT_ID}\",
    \"client_secret\": \"${AUTH0_M2M_CLIENT_SECRET}\",
    \"audience\": \"${MGMT_AUDIENCE}\",
    \"grant_type\": \"client_credentials\"
  }") || fail "Could not get Management API token — check M2M client id/secret and API authorization"

MGMT_TOKEN=$(echo "$TOKEN_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
ok "Management API token obtained"

info "Enabling Dynamic Client Registration (DCR)..."
api PATCH /tenants/settings -d '{"flags":{"enable_dynamic_client_registration":true}}' >/dev/null
ok "DCR enabled"

info "Enabling Identifier First (required for passwordless email on New Universal Login)..."
api PATCH /prompts -d '{"universal_login_experience":"new","identifier_first":true}' >/dev/null
ok "Identifier First enabled"

DCR_TEST=$(curl -sS -X POST "https://${DOMAIN}/oidc/register" \
  -H "content-type: application/json" \
  -d "{\"client_name\":\"acs-setup-test\",\"redirect_uris\":[\"${CLAUDE_CALLBACK}\"]}" || true)
if echo "$DCR_TEST" | grep -q '"client_id"'; then
  ok "DCR registration test passed"
elif echo "$DCR_TEST" | grep -q 'too_many_entities'; then
  ok "DCR enabled (tenant at DCR client limit — delete old test apps in Auth0 if needed)"
else
  fail "DCR still failing: $DCR_TEST"
fi

info "Finding MCP API (audience: ${AUDIENCE})..."
MCP_API_ID=$(api GET /resource-servers | python3 -c "
import sys, json
aud = sys.argv[1]
for rs in json.load(sys.stdin):
    if rs.get('identifier') == aud:
        print(rs['id'])
        break
" "$AUDIENCE")

if [[ -z "$MCP_API_ID" ]]; then
  info "Creating MCP API..."
  MCP_API_ID=$(api POST /resource-servers -d "{
    \"name\": \"Steward ACS MCP\",
    \"identifier\": \"${AUDIENCE}\",
    \"signing_alg\": \"RS256\",
    \"token_lifetime\": 86400
  }" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
  ok "Created MCP API id=${MCP_API_ID}"
else
  ok "Found MCP API id=${MCP_API_ID}"
fi

info "Enabling RBAC + permissions in access token..."
api PATCH "/resource-servers/${MCP_API_ID}" -d '{
  "enforce_policies": true,
  "token_dialect": "access_token_authz"
}' >/dev/null
ok "RBAC enabled (token_dialect=access_token_authz)"

info "Ensuring mcp:tools permission exists..."
RS_INFO=$(api GET "/resource-servers/${MCP_API_ID}")
HAS_SCOPE=$(echo "$RS_INFO" | python3 -c "
import sys, json
rs = json.load(sys.stdin)
scopes = rs.get('scopes') or []
print('yes' if any(s.get('value') == 'mcp:tools' for s in scopes) else 'no')
")
if [[ "$HAS_SCOPE" == "yes" ]]; then
  ok "Permission mcp:tools already exists"
else
  SCOPES_JSON=$(echo "$RS_INFO" | python3 -c "
import sys, json
rs = json.load(sys.stdin)
scopes = rs.get('scopes') or []
scopes.append({'value': 'mcp:tools', 'description': 'Call Steward ACS MCP tools'})
print(json.dumps({'scopes': scopes}))
")
  api PATCH "/resource-servers/${MCP_API_ID}" -d "$SCOPES_JSON" >/dev/null
  ok "Added permission mcp:tools via PATCH"
fi

info "Ensuring MCP User role..."
ROLES=$(api GET /roles?name_filter=MCP%20User)
ROLE_ID=$(echo "$ROLES" | python3 -c "
import sys, json
roles = json.load(sys.stdin)
for r in roles:
    if r.get('name') == 'MCP User':
        print(r['id'])
        break
" || true)

if [[ -z "$ROLE_ID" ]]; then
  ROLE_ID=$(api POST /roles -d '{"name":"MCP User","description":"Can use Steward MCP tools via Claude"}' \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
  ok "Created role MCP User id=${ROLE_ID}"
else
  ok "Found role MCP User id=${ROLE_ID}"
fi

info "Assigning mcp:tools to MCP User role..."
api POST "/roles/${ROLE_ID}/permissions" -d "[{
  \"resource_server_identifier\": \"${AUDIENCE}\",
  \"permission_name\": \"mcp:tools\"
}]" >/dev/null 2>&1 || true
ok "Role permission assigned (or already present)"

info "Configuring default third-party API access (required for DCR Claude clients)..."
EXISTING_GRANTS=$(api GET "/client-grants?audience=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${AUDIENCE}'))")" 2>/dev/null || echo "[]")
HAS_DEFAULT=$(echo "$EXISTING_GRANTS" | python3 -c "
import sys, json
grants = json.load(sys.stdin) if sys.stdin.readable() else []
for g in grants:
    if g.get('default_for') == 'third_party_clients' and g.get('audience') == sys.argv[1]:
        print('yes'); break
else:
    print('no')
" "$AUDIENCE" 2>/dev/null || echo "no")

if [[ "$HAS_DEFAULT" == "yes" ]]; then
  ok "Default third-party client grant already exists"
else
  api POST /client-grants -d "{
    \"default_for\": \"third_party_clients\",
    \"audience\": \"${AUDIENCE}\",
    \"scope\": [\"mcp:tools\"],
    \"subject_type\": \"user\"
  }" >/dev/null
  ok "Created default third-party grant for ${AUDIENCE}"
fi

# Per-app grants for known Claude OAuth clients
for CLAUDE_CID in $(api GET "/clients?fields=client_id,name&include_fields=true&per_page=100" | python3 -c "
import sys, json
for c in json.load(sys.stdin):
    n = (c.get('name') or '').lower()
    if 'claude' in n:
        print(c['client_id'])
"); do
  HAS_GRANT=$(echo "$EXISTING_GRANTS" | python3 -c "
import sys, json
cid, aud = sys.argv[1], sys.argv[2]
grants = json.load(sys.stdin) if sys.stdin.readable() else []
print('yes' if any(g.get('client_id')==cid and g.get('audience')==aud for g in grants) else 'no')
" "$CLAUDE_CID" "$AUDIENCE" 2>/dev/null || echo "no")
  if [[ "$HAS_GRANT" != "yes" ]]; then
    api POST /client-grants -d "{
      \"client_id\": \"${CLAUDE_CID}\",
      \"audience\": \"${AUDIENCE}\",
      \"scope\": [\"mcp:tools\"],
      \"subject_type\": \"user\"
    }" >/dev/null 2>&1 || true
    ok "Granted MCP API access to client ${CLAUDE_CID}"
  fi
done

if [[ -n "${AUTH0_USER_EMAIL:-}" ]]; then
  [[ -n "${AUTH0_USER_ORG:-}" ]] || fail "Set AUTH0_USER_ORG when creating or updating an Auth0 user"
  ORG_META="${AUTH0_USER_ORG}"
  ROLE_META="${AUTH0_USER_ROLE:-collaborator}"
  info "Creating passwordless user ${AUTH0_USER_EMAIL} on connection ${DB_CONNECTION} (org=${ORG_META})..."
  if [[ "$DB_CONNECTION" == "email" || "$DB_CONNECTION" == "sms" ]]; then
    USER_JSON=$(api POST /users -d "{
      \"email\": \"${AUTH0_USER_EMAIL}\",
      \"connection\": \"${DB_CONNECTION}\",
      \"email_verified\": true,
      \"app_metadata\": {\"org\": \"${ORG_META}\", \"role\": \"${ROLE_META}\"}
    }" 2>/dev/null || true)
  else
    [[ -n "${AUTH0_USER_PASSWORD:-}" ]] || fail "Set AUTH0_USER_PASSWORD when AUTH0_DB_CONNECTION is a database connection"
    USER_JSON=$(api POST /users -d "{
      \"email\": \"${AUTH0_USER_EMAIL}\",
      \"password\": \"${AUTH0_USER_PASSWORD}\",
      \"connection\": \"${DB_CONNECTION}\",
      \"email_verified\": true,
      \"app_metadata\": {\"org\": \"${ORG_META}\", \"role\": \"${ROLE_META}\"}
    }" 2>/dev/null || true)
  fi

  USER_ID=$(echo "$USER_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('user_id',''))" 2>/dev/null || true)

  if [[ -z "$USER_ID" ]]; then
    USER_ID=$(api GET "/users-by-email?email=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${AUTH0_USER_EMAIL}'))")" \
      | python3 -c "import sys,json; u=json.load(sys.stdin); print(u[0]['user_id'] if u else '')")
    api PATCH "/users/${USER_ID}" -d "{\"app_metadata\":{\"org\":\"${ORG_META}\",\"role\":\"${ROLE_META}\"}}" >/dev/null 2>&1 || true
    ok "User already exists id=${USER_ID} (org=${ORG_META})"
  else
    ok "Created user id=${USER_ID}"
  fi

  api POST "/users/${USER_ID}/roles" -d "{\"roles\": [\"${ROLE_ID}\"]}" >/dev/null
  ok "Assigned MCP User role to ${AUTH0_USER_EMAIL}"
fi

if [[ "${SKIP_CLAUDE_APP:-}" != "1" ]]; then
  info "Creating Claude.ai OAuth app (manual Client ID fallback)..."
  EXISTING=$(api GET /clients?fields=client_id,name 2>/dev/null | python3 -c "
import sys, json
for c in json.load(sys.stdin):
    if c.get('name') == 'Claude.ai MCP':
        print(c['client_id'])
        break
" || true)

  if [[ -n "$EXISTING" ]]; then
    CLAUDE_CLIENT_ID="$EXISTING"
    ok "Claude.ai MCP app already exists client_id=${CLAUDE_CLIENT_ID}"
  else
    CLAUDE_CLIENT_ID=$(api POST /clients -d "{
      \"name\": \"Claude.ai MCP\",
      \"app_type\": \"regular_web\",
      \"callbacks\": [\"${CLAUDE_CALLBACK}\"],
      \"grant_types\": [\"authorization_code\", \"refresh_token\"],
      \"token_endpoint_auth_method\": \"none\",
      \"oidc_conformant\": true
    }" | python3 -c "import sys,json; print(json.load(sys.stdin)['client_id'])")
    ok "Created Claude.ai MCP app client_id=${CLAUDE_CLIENT_ID}"
  fi

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " Claude Connector OAuth Client ID (if DCR fails):"
  echo " ${CLAUDE_CLIENT_ID}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
fi

# After Claude apps exist: wire passwordless email, demote password DB
CLAUDE_IDS=$(api GET "/clients?fields=client_id,name&include_fields=true&per_page=100" | python3 -c "
import sys, json
for c in json.load(sys.stdin):
    n = (c.get('name') or '')
    if n in ('Claude.ai MCP', 'steward_acs_mcp'):
        print(c['client_id'])
")

info "Configuring passwordless email connection for Claude (domain-level + first-party apps)..."
EMAIL_CONN=$(api GET "/connections?strategy=email" | python3 -c "
import sys, json
conns = json.load(sys.stdin)
print(conns[0]['id'] if conns else '')
" 2>/dev/null || true)

if [[ -n "$EMAIL_CONN" ]]; then
  ENABLED_JSON=$(api GET "/connections/${EMAIL_CONN}" | python3 -c "
import sys, json
conn = json.load(sys.stdin)
clients = set(conn.get('enabled_clients') or [])
for cid in '''${CLAUDE_IDS}'''.split():
    if cid:
        clients.add(cid)
print(json.dumps({'is_domain_connection': True, 'enabled_clients': sorted(clients)}))
")
  api PATCH "/connections/${EMAIL_CONN}" -d "$ENABLED_JSON" >/dev/null
  ok "Email passwordless connection is domain-level and enabled for Claude apps"
else
  info "No email passwordless connection found — create one in Auth0 Dashboard (Authentication → Passwordless → Email)"
fi

info "Demoting Username-Password-Authentication (Claude should use email OTP, not passwords)..."
DB_CONN=$(api GET "/connections?name=Username-Password-Authentication" | python3 -c "
import sys, json
conns = json.load(sys.stdin)
print(conns[0]['id'] if conns else '')
" 2>/dev/null || true)
if [[ -n "$DB_CONN" ]]; then
  PATCH_JSON=$(api GET "/connections/${DB_CONN}" | python3 -c "
import sys, json
conn = json.load(sys.stdin)
claude = set('''${CLAUDE_IDS}'''.split())
clients = [c for c in (conn.get('enabled_clients') or []) if c not in claude]
print(json.dumps({'is_domain_connection': False, 'enabled_clients': clients}))
")
  api PATCH "/connections/${DB_CONN}" -d "$PATCH_JSON" >/dev/null
  ok "Database connection demoted (not domain-level; Claude apps removed)"
fi

echo ""
ok "Auth0 setup complete for ${DOMAIN}"
echo "  MCP API:     ${AUDIENCE}"
echo "  DCR:         enabled"
echo "  Login:       Identifier First + passwordless email OTP (connection=email)"
echo "  RBAC:        enabled with mcp:tools"
echo ""
echo "Next: Remove + re-add Claude connector at ${AUDIENCE} and connect."
echo "Users enter email → receive a one-time code (New Universal Login; not Classic magic links)."