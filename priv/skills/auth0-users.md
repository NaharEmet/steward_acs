---
audit_reasoning: "The skill is highly actionable with clear, step-by-step instructions for multiple methods (script, dashboard, API), includes prerequisites, verification steps, and a comprehensive troubleshooting table. The description is distinct and accurately summarizes the skill's purpose. It is unique and not a duplicate of existing skills."
audit_score: 10
audit_status: "ok"
audited_at: "2026-07-15T14:43:55.018135Z"
description: Create Auth0 users for Claude MCP Connectors on prod ACS
name: "auth0-users"
scope_paths: ["guides/deployment", "lib/acs_web", "auth"]
when_to_use: When setting up OAuth users for Claude Connectors on production ACS
tags: ["auth0", "oauth", "users", "admin", "connectors"]
---

# Auth0 Users for Claude Connectors

Claude **Custom Connectors** sign in via **Auth0 OAuth** — not `acs_dev_...` API keys.

| Auth path | Who uses it |
|-----------|-------------|
| **Auth0 passwordless email OTP** | Claude web Connectors (`https://prod.stewardacs.xyz/mcp/sse`) |
| **`acs_dev_...` key** | Claude Code, Steward Bridge plugin, scripts |

Prod tenant: `dev-jw5wgp2b.us.auth0.com`  
MCP API audience: `https://prod.stewardacs.xyz/mcp/sse`  
Required permission: `mcp:tools` (via **MCP User** role)

## Org model (single org per user)

Every OAuth access token must carry `https://stewardacs.xyz/org`. That claim is
the authenticated org; an org subdomain is only an optional matching hint.
There are no multi-org memberships or org switcher yet.

After a clean database rebuild, re-create or re-stamp each retained Auth0 user
with its org in `app_metadata.org`, ensure the Auth0 Action emits the namespaced
claim, then reconnect clients to obtain fresh tokens. Never infer the user's org
from the connector URL.

## Login model

- **New Universal Login** + **Identifier First**
- Caddy `/authorize` injects `connection=email` (passwordless OTP)
- Users enter email → receive a one-time code (not a username/password form)
- Auth0 **magic links** require Classic Login; we use email OTP on New UL instead

Tenant bootstrap: `./scripts/setup-auth0.sh` (M2M creds in `certs/Oauth.md` or env).

---

## Create a user (recommended — script)

```bash
export AUTH0_USER_EMAIL="newuser@example.com"
export AUTH0_USER_ORG="org-slug"  # required; never defaults implicitly
export SKIP_CLAUDE_APP=1           # skip re-creating Claude OAuth app

./scripts/add-auth0-org-user.sh
```

The script will:
1. Create/update the user on the **email** passwordless connection (no password)
2. Set `app_metadata.org` to the required single-org slug
3. Assign the **MCP User** role (`mcp:tools`)
4. Install/deploy the post-login Action that emits `https://stewardacs.xyz/org`
5. Mark email verified

Tell the user: **Settings → Connectors →** `https://prod.stewardacs.xyz/mcp/sse` → enter email → use the code from Resend/email.

---

## Create a user (Auth0 Dashboard)

1. **User Management → Users → Create user**
2. **Connection:** `email` (Passwordless)
3. **Email** (no password)
4. Set `app_metadata` to `{"org":"org-slug","role":"collaborator"}`
5. **User Management → Roles → MCP User → Add Members** → select the user
6. Confirm the deployed **ACS org claim** post-login Action is bound to the login flow

If **MCP User** role is missing, create it:
- **Permissions:** API `https://prod.stewardacs.xyz/mcp/sse` → `mcp:tools`

---

## Create a user (Management API)

```bash
curl -sS -X POST "https://dev-jw5wgp2b.us.auth0.com/oauth/token" \
  -H 'content-type: application/json' \
  -d @certs/Oauth.md
# Use access_token from response as $MGMT_TOKEN

curl -sS -X POST "https://dev-jw5wgp2b.us.auth0.com/api/v2/users" \
  -H "authorization: Bearer $MGMT_TOKEN" \
  -H 'content-type: application/json' \
  -d '{
    "email": "newuser@example.com",
    "connection": "email",
    "email_verified": true,
    "app_metadata": {"org": "org-slug", "role": "collaborator"}
  }'

curl -sS -X POST "https://dev-jw5wgp2b.us.auth0.com/api/v2/users/USER_ID/roles" \
  -H "authorization: Bearer $MGMT_TOKEN" \
  -H 'content-type: application/json' \
  -d '{"roles": ["rol_8v0cgNbkP8DePo0O"]}'
```

Replace `USER_ID` with the create response (e.g. `email|...`). Confirm role id in Dashboard if unsure. Ensure the **ACS org claim** post-login Action from `add-auth0-org-user.sh` is deployed and bound before login.

After reconnecting, decode the access token payload and verify it contains both
`"https://stewardacs.xyz/org": "org-slug"` and `mcp:tools` (or `mcp:admin`).
ACS rejects tokens missing either value.

---

## Remove / disable a user

**Dashboard:** User Management → Users → select user → **Delete** or block.

**API:** `DELETE /api/v2/users/{id}`

Revoke active sessions: disconnect the connector in Claude; tokens expire per Auth0 API settings.

---

## Troubleshooting login

| Symptom | Fix |
|---------|-----|
| `invalid_request: ID First not enabled for the client` | Enable Identifier First: Auth0 → Authentication → Authentication Profile, or `PATCH /api/v2/prompts` with `identifier_first: true`. Re-run `./scripts/setup-auth0.sh`. |
| Auth0 “Oops” + password form | Password DB must **not** be domain-level; email passwordless **must** be. Caddy must inject `connection=email` on `/authorize`. |
| `the connection is not enabled` | Enable **email** connection for first-party Claude apps (`Claude.ai MCP`, `steward_acs_mcp`) — setup script does this. |
| “Couldn't register with sign-in service” / Auth0 `too_many_entities` on `/oidc/register` | Free Auth0 tenants fill up with Claude DCR apps. Prune with `python3 scripts/cleanup-auth0-dcr-clients.py --delete` (third-party only). |
| Auth0 `cls` success then `fn` fail: Resend `domain is not verified` | Passwordless **From** and Branding → Email Provider **From** must use a Resend-verified domain (e.g. `noreply@stewardacs.xyz`), **not** an unverified org domain like `@safetyconnect.io`. Recipient can still be `@safetyconnect.io`. Fix: `AUTH0_EMAIL_FROM='Steward ACS <noreply@stewardacs.xyz>' python3 scripts/fix-auth0-email-from.py --fix` |
| “Couldn't register with sign-in service” | Enable **OIDC Dynamic Application Registration** or use manual Claude Client ID from setup script |
| User logs in but no MCP tools | Assign **MCP User** role; **reconnect** connector for a fresh token with `permissions` |

Verify ACS OAuth metadata:

```bash
curl -s https://prod.stewardacs.xyz/.well-known/oauth-protected-resource/mcp/sse
```

---

## Do not confuse with ACS developer keys

**Auth0 users** ≠ **`acs_dev_...` keys**.

- Generate developer keys from the ACS dashboard / Developers API for plugins and Claude Code.
- Auth0 users are only for Claude **Connectors** OAuth on prod.
