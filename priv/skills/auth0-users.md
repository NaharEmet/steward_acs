---
audit_reasoning: All checks passed
audit_score: 10
audit_status: ok
audited_at: 2026-07-05T11:19:22.723653Z
description: Create Auth0 users for Claude MCP Connectors on prod ACS
name: auth0-users
tags: ["auth0", "oauth", "users", "admin", "connectors"]
---

# Auth0 Users for Claude Connectors

Claude **Custom Connectors** sign in via **Auth0 OAuth** — not `acs_dev_...` API keys.

| Auth path | Who uses it |
|-----------|-------------|
| **Auth0 user** | Claude web Connectors (`https://prod.stewardacs.xyz/mcp/sse`) |
| **`acs_dev_...` key** | Claude Code, Steward Bridge plugin, scripts |

Prod tenant: `dev-jw5wgp2b.us.auth0.com`  
MCP API audience: `https://prod.stewardacs.xyz/mcp/sse`  
Required permission: `mcp:tools` (via **MCP User** role)

Tenant bootstrap (DCR, RBAC, client grants, domain-level DB): run once with `./scripts/setup-auth0.sh` (see `certs/Oauth.md` for M2M credentials).

---

## Create a user (recommended — script)

From the repo root, with M2M creds in `certs/Oauth.md` or env:

```bash
export AUTH0_USER_EMAIL="newuser@example.com"
export AUTH0_USER_PASSWORD="Choose-A-Strong-Password!"
export SKIP_CLAUDE_APP=1   # skip re-creating Claude OAuth app

./scripts/setup-auth0.sh
```

The script will:
1. Create the user on **Username-Password-Authentication**
2. Assign the **MCP User** role (`mcp:tools`)
3. Mark email verified (so login is not blocked)

Tell the user to connect in Claude: **Settings → Connectors →** `https://prod.stewardacs.xyz/mcp/sse` → sign in with that email/password.

---

## Create a user (Auth0 Dashboard)

1. **User Management → Users → Create user**
2. **Connection:** `Username-Password-Authentication`
3. **Email** + **Password**
4. **User Management → Roles → MCP User → Add Members** → select the user

If **MCP User** role is missing, create it:
- **Permissions:** API `https://prod.stewardacs.xyz/mcp/sse` → `mcp:tools`

---

## Create a user (Management API)

Get a token (M2M app authorized for Auth0 Management API):

```bash
curl -sS -X POST "https://dev-jw5wgp2b.us.auth0.com/oauth/token" \
  -H 'content-type: application/json' \
  -d @certs/Oauth.md
# Use access_token from response as $MGMT_TOKEN
```

Create user:

```bash
curl -sS -X POST "https://dev-jw5wgp2b.us.auth0.com/api/v2/users" \
  -H "authorization: Bearer $MGMT_TOKEN" \
  -H 'content-type: application/json' \
  -d '{
    "email": "newuser@example.com",
    "password": "Choose-A-Strong-Password!",
    "connection": "Username-Password-Authentication",
    "email_verified": true
  }'
```

Assign **MCP User** role (`rol_8v0cgNbkP8DePo0O` on prod — confirm in Dashboard if unsure):

```bash
curl -sS -X POST "https://dev-jw5wgp2b.us.auth0.com/api/v2/users/USER_ID/roles" \
  -H "authorization: Bearer $MGMT_TOKEN" \
  -H 'content-type: application/json' \
  -d '{"roles": ["rol_8v0cgNbkP8DePo0O"]}'
```

Replace `USER_ID` with the value from the create response (e.g. `auth0|...`).

---

## Remove / disable a user

**Dashboard:** User Management → Users → select user → **Delete** or block.

**API:** `DELETE /api/v2/users/{id}`

Revoke active sessions: user must disconnect the connector in Claude; tokens expire per Auth0 API settings.

---

## Troubleshooting login

| Symptom | Fix |
|---------|-----|
| Auth0 “Oops, something went wrong” | Check **Monitoring → Logs**. Usually missing **client grant** for Claude app on MCP API — re-run `./scripts/setup-auth0.sh` |
| “Couldn't register with sign-in service” | Enable **OIDC Dynamic Application Registration** (tenant settings) or use manual Claude Client ID from setup script |
| User logs in but no MCP tools | Assign **MCP User** role; user must **reconnect** connector for fresh token with `permissions` |
| No login form / wrong connection | **Username-Password-Authentication** must be **domain-level** (third-party/DCR apps) — `./scripts/setup-auth0.sh` sets this |

Verify ACS OAuth metadata:

```bash
curl -s https://prod.stewardacs.xyz/.well-known/oauth-protected-resource/mcp/sse
```

---

## Do not confuse with ACS developer keys

**Auth0 users** ≠ **`acs_dev_...` keys**.

- Generate developer keys from the ACS dashboard / Developers API for plugins and Claude Code.
- Auth0 users are only for Claude **Connectors** OAuth on prod.
