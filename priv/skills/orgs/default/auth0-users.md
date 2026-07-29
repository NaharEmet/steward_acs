---
audit_reasoning: "This is an exemplary skill. It is highly actionable with clear, numbered steps for three distinct methods (script, dashboard, API). It includes comprehensive prerequisites, verification steps, and a detailed troubleshooting table for failure recovery. The description is distinct and informative. The content is rich with concrete examples, including exact file paths, command snippets, API endpoints, and role IDs. The audience fit is perfect for a 'coding' agent, providing the technical depth needed for implementation. It is unique and not a duplicate of existing skills."
audit_score: 10
audit_status: "ok"
audited_at: "2026-07-29T04:34:59.229071Z"
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
| **Auth0** email OTP and/or Google | Claude web Connectors — chat: `https://prod.stewardacs.xyz/mcp/chat/sse`; coding: `https://prod.stewardacs.xyz/mcp/sse` |
| **`acs_dev_...` key** | Claude Code, Steward Bridge plugin, scripts |

Prod tenant: `dev-jw5wgp2b.us.auth0.com`  
MCP API audience: `https://prod.stewardacs.xyz/mcp/sse`  
Required permission: `mcp:tools` (via **MCP User** role)

## Login model

- **New Universal Login** + **Identifier First**
- **Email OTP and/or Google** — both connections enabled on Steward web + Claude MCP clients (`./scripts/setup-auth0.sh`)
- Do **not** pin `connection=` in Caddy `/authorize` or web OIDC (leave `AUTH0_CONNECTION` unset) so UL shows the choice
- Optional pin: set `AUTH0_CONNECTION=email` or `google-oauth2` only if you want to force one method
- ACS reconnects by **verified email** when Auth0 `sub` differs across connections (`upsert_oidc_user` + MCP email fallback)
- Users should use the **same email** for Google and passwordless; Auth0 still creates two identities — assign **MCP User** on whichever Auth0 user Claude uses
- Auth0 **magic links** require Classic Login; we use email OTP on New UL instead

Tenant bootstrap: `./scripts/setup-auth0.sh` (M2M creds in `certs/Oauth.md` or env). That script enables `email` + `google-oauth2` on the Steward web + Claude MCP clients.

---

## Create a user (recommended — script)

```bash
export AUTH0_USER_EMAIL="newuser@example.com"
export SKIP_CLAUDE_APP=1   # skip re-creating Claude OAuth app

./scripts/setup-auth0.sh
```

The script will:
1. Create the user on the **email** passwordless connection (no password)
2. Assign the **MCP User** role (`mcp:tools`)
3. Mark email verified

Tell the user: **Settings → Connectors →** `https://prod.stewardacs.xyz/mcp/chat/sse` (chat) or `https://prod.stewardacs.xyz/mcp/sse` (coding) → sign in with email OTP or Google (same verified email as the website).

Auth0 API identifier: `https://prod.stewardacs.xyz/mcp/sse` for both. ACS picks chat vs coding from the SSE path.

---

## Create a user (Auth0 Dashboard)

1. **User Management → Users → Create user**
2. **Connection:** `email` (Passwordless)
3. **Email** (no password)
4. **User Management → Roles → MCP User → Add Members** → select the user

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
    "email_verified": true
  }'

curl -sS -X POST "https://dev-jw5wgp2b.us.auth0.com/api/v2/users/USER_ID/roles" \
  -H "authorization: Bearer $MGMT_TOKEN" \
  -H 'content-type: application/json' \
  -d '{"roles": ["rol_8v0cgNbkP8DePo0O"]}'
```

Replace `USER_ID` with the create response (e.g. `email|...`). Confirm role id in Dashboard if unsure.

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
| Auth0 “Oops” + password form | Password DB must **not** be domain-level; email passwordless **must** be. Do not enable Username-Password for Claude/web clients. |
| `the connection is not enabled` | Enable **email** connection for first-party Claude apps (`Claude.ai MCP`, `steward_acs_mcp`) — setup script does this. |
| “Couldn't register with sign-in service” / Auth0 `too_many_entities` on `/oidc/register` | Free Auth0 tenants fill up with Claude DCR apps. Prune with `python3 scripts/cleanup-auth0-dcr-clients.py --delete` (third-party only). |
| Auth0 `cls` success then `fn` fail: Resend `domain is not verified` | Passwordless **From** and Branding → Email Provider **From** must use a Resend-verified domain (e.g. `noreply@stewardacs.xyz`), **not** an unverified org domain like `@safetyconnect.io`. Recipient can still be `@safetyconnect.io`. Fix: `AUTH0_EMAIL_FROM='Steward ACS <noreply@stewardacs.xyz>' python3 scripts/fix-auth0-email-from.py --fix` |
| “Couldn't register with sign-in service” | Enable **OIDC Dynamic Application Registration** or use manual Claude Client ID from setup script |
| User logs in but no MCP tools | Assign **MCP User** role; **reconnect** connector for a fresh token with `permissions` |
| Claude: “Couldn't connect / Taking you back to the desktop app” after OTP | Auth0 login succeeded but ACS rejected the token. Check prod logs for `OAuth user is not authorized`. Common causes: (1) ACS user missing for that org; (2) **MCP User role missing `mcp:tools` on that tenant audience** (role had only `https://prod.stewardacs.xyz/mcp/sse` — run `scripts/ensure-auth0-org-audiences.sh` and attach role permissions per org API); (3) legacy Google vs email identity split. Reconnect after fixing so Claude gets a fresh token. |

Verify ACS OAuth metadata:

```bash
curl -s https://prod.stewardacs.xyz/.well-known/oauth-protected-resource/mcp/sse
```

---

## Do not confuse with ACS developer keys

**Auth0 users** ≠ **`acs_dev_...` keys**.

- Generate developer keys from the ACS dashboard / Developers API for plugins and Claude Code.
- Auth0 users are only for Claude **Connectors** OAuth on prod.
