---
description: "Create Auth0 users and enable email OTP + Google for web portal and Claude/ChatGPT MCP connectors"
name: "auth0-users"
proposed_by: "nahar emet"
scope_paths: ["guides/deployment", "lib/acs_web", "auth", "scripts"]
status: "approved"
tags: ["auth0", "oauth", "users", "admin", "connectors", "chatgpt", "google"]
when_to_use: "When setting up OAuth users, enabling Google login, or fixing Claude/ChatGPT connector login on production ACS"
audit_reasoning: "This is an exceptionally well-structured and comprehensive skill. It provides clear, actionable, step-by-step instructions for a complex administrative task (Auth0 user and connection management). The content is rich with concrete examples, including exact API endpoints, command-line snippets, specific Auth0 client IDs, and troubleshooting tables. The prerequisites (like M2M credentials) are implied by the script references. The verification and failure recovery sections are thorough, covering common pitfalls. The description is distinct and accurately summarizes the skill's purpose. The audience ('coding') is appropriate, as the task involves API calls, scripts, and configuration management suitable for a developer or DevOps agent. The scope is well-defined and matches the content."
audit_score: 10
audit_status: "ok"
audited_at: "2026-08-04T06:33:56.097553Z"
approved_at: "2026-08-04T06:33:56.104486Z"
approved_by: "llm"
reviewed_at: "2026-08-04T06:33:56.104486Z"
reviewed_by: "llm"
---

# Auth0 Users for Claude / ChatGPT Connectors

Claude and ChatGPT **Custom Connectors** sign in via **Auth0 OAuth** — not `acs_dev_...` API keys. The **web portal** uses the same Auth0 tenant via the Steward web OIDC app (`AUTH0_WEB_CLIENT_ID`).

| Auth path | Who uses it |
|-----------|-------------|
| **Auth0** email OTP and/or Google | Web portal + Claude / ChatGPT Connectors — chat: `https://prod.stewardacs.xyz/mcp/chat/sse`; coding: `https://prod.stewardacs.xyz/mcp/sse` |
| **`acs_dev_...` key** | Claude Code, Steward Bridge plugin, scripts |

Prod tenant: `dev-jw5wgp2b.us.auth0.com`  
MCP API audience: `https://prod.stewardacs.xyz/mcp/sse`  
Required permission: `mcp:tools` (via **MCP User** role)

**Fixed DCR:** ACS `/oidc/register` always returns `OAUTH_FIXED_DCR_CLIENT_ID` (prod: `0Qt3zP1YbyjtVN9zRf2cN7Pt39NhkHp0`). Auth0 still checks `redirect_uri` against that app's Allowed Callback URLs — Claude alone is not enough for ChatGPT.

## Login model

- **New Universal Login** + **Identifier First**
- **Email OTP and/or Google** — both connections enabled on Steward web + connector clients (`./scripts/setup-auth0.sh`)
- Do **not** pin `connection=` in Caddy `/authorize` or web OIDC (leave `AUTH0_CONNECTION` unset) so UL shows the choice
- Optional pin: set `AUTH0_CONNECTION=email` or `google-oauth2` only if you want to force one method
- ACS reconnects by **verified email** when Auth0 `sub` differs across connections (`upsert_oidc_user` + MCP email fallback)
- Users should use the **same email** for Google and passwordless; Auth0 still creates two identities — assign **MCP User** on whichever Auth0 user the connector uses
- Auth0 **magic links** require Classic Login; we use email OTP on New UL instead

Tenant bootstrap: `./scripts/setup-auth0.sh` (M2M creds in `certs/Oauth.md` or env). That script enables `email` + `google-oauth2` and unions **Claude + ChatGPT** callbacks on connector / fixed-DCR apps.

---

## Enable Google login (web portal + MCP)

ACS code already accepts Google (`google-oauth2` subjects, email-verified claims). Auth0 must expose Google on **both** apps.

### Steps (Auth0 Dashboard)

1. **Google Cloud Console** → APIs & Services → Credentials → Create **OAuth 2.0 Client ID** (Web application).
   - Authorized redirect URI: `https://dev-jw5wgp2b.us.auth0.com/login/callback`
2. Auth0 → **Authentication → Social → Create Connection → Google** (or open existing).
   - Paste Google Client ID + Client Secret.
   - Attributes: at least `email`, `email_verified`, `name` / profile.
3. On that connection → **Applications** tab — enable:
   - Steward **web** app (`AUTH0_WEB_CLIENT_ID` from Infisical)
   - Fixed DCR / MCP app `0Qt3zP1YbyjtVN9zRf2cN7Pt39NhkHp0` (and `Claude.ai MCP` / `steward_acs_mcp` if separate)
4. Confirm host thin `.env` has **`AUTH0_CONNECTION` unset/empty** (do not pin `email`). Compose already passes `${AUTH0_CONNECTION:-}`.
5. Web app Allowed Callback URLs must include `https://prod.stewardacs.xyz/auth/callback` (and account host if used).
6. Try web: open portal → Sign in → Universal Login should offer **Continue with Google** and email OTP.
7. Try MCP: reconnect Claude/ChatGPT connector → same UL choice.
8. After first Google login for MCP, assign **MCP User** role to the new `google-oauth2|…` Auth0 user (or rely on email merge if they already had OTP with the same verified email — still assign role if tools missing).

### Script path (when M2M works)

```bash
export AUTH0_WEB_CLIENT_ID=…          # Steward web OIDC app
export OAUTH_FIXED_DCR_CLIENT_ID=0Qt3zP1YbyjtVN9zRf2cN7Pt39NhkHp0
SKIP_CLAUDE_APP=1 ./scripts/setup-auth0.sh
```

Script enables `google-oauth2` on web + Claude named apps + fixed DCR client. It does **not** create the Google social connection or Google Cloud OAuth client — do steps 1–2 once in the dashboards.

### Verification

- Auth0 Google connection lists web + MCP apps enabled.
- UL shows Google button (not email-only).
- Web sign-in with Google reaches ACS dashboard/onboarding.
- MCP connector sign-in with Google yields tools (`mcp:tools` on token).

---

## Fix ChatGPT "Callback URL mismatch" (prod)

### Steps

1. Confirm the fixed client: `curl -sS -X POST https://prod.stewardacs.xyz/oidc/register -H 'content-type: application/json' -d '{"client_name":"diag","redirect_uris":["https://chatgpt.com/connector_platform_oauth_redirect"]}'` → note `client_id`.
2. Auth0 Dashboard → **Applications** → that client (or search by client_id) → **Settings** → **Allowed Callback URLs**.
3. Ensure these are present (comma-separated with Claude's URL):
   - `https://claude.ai/api/mcp/auth_callback`
   - `https://chatgpt.com/connector_platform_oauth_redirect`
   - `https://platform.openai.com/apps-manage/oauth`
4. If ChatGPT shows a per-app URL like `https://chatgpt.com/connector/oauth/<id>`, add that exact URL too (Auth0 has no path wildcards).
5. Save → remove + re-add the ChatGPT connector → sign in again.

### Script path (when M2M works)

```bash
export OAUTH_FIXED_DCR_CLIENT_ID=0Qt3zP1YbyjtVN9zRf2cN7Pt39NhkHp0
# optional Apps SDK URL:
# export CHATGPT_EXTRA_CALLBACKS='https://chatgpt.com/connector/oauth/<id>'
SKIP_CLAUDE_APP=1 ./scripts/setup-auth0.sh
```

### Verification

- Auth0 app Allowed Callback URLs include both Claude and ChatGPT URLs above.
- ChatGPT connector OAuth completes past Auth0 without "Callback URL mismatch".

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
4. Sync Claude + ChatGPT callbacks onto connector / fixed-DCR apps

Tell the user: **Settings → Connectors →** `https://prod.stewardacs.xyz/mcp/chat/sse` (chat) or `https://prod.stewardacs.xyz/mcp/sse` (coding) → sign in with email OTP or Google (same verified email as the website).

Auth0 API identifier: `https://prod.stewardacs.xyz/mcp/sse` for both. ACS picks chat vs coding from the SSE path.

Google-first users: they self-create on first Google login — still assign **MCP User** for connector tokens.

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

Revoke active sessions: disconnect the connector in Claude/ChatGPT; tokens expire per Auth0 API settings.

---

## Troubleshooting login

| Symptom | Fix |
|---------|-----|
| No Google button on Universal Login | Create/enable Google social connection; enable it on **web** + **fixed DCR** apps; leave `AUTH0_CONNECTION` unset. See Enable Google section. |
| `the connection is not enabled` for Google | Enable `google-oauth2` on that Auth0 application (Applications tab on the connection). |
| Google works on web but not MCP (or reverse) | Different Auth0 apps — enable Google on **both** `AUTH0_WEB_CLIENT_ID` and `OAUTH_FIXED_DCR_CLIENT_ID`. |
| Auth0 **Callback URL mismatch** / redirect_uri not allowed (esp. ChatGPT) | Add ChatGPT callbacks to the **fixed DCR** Auth0 app (`OAUTH_FIXED_DCR_CLIENT_ID`). See section above. ACS DCR echoes redirect_uris but Auth0 enforces the app allowlist. |
| `invalid_request: ID First not enabled for the client` | Enable Identifier First: Auth0 → Authentication → Authentication Profile, or `PATCH /api/v2/prompts` with `identifier_first: true`. Re-run `./scripts/setup-auth0.sh`. |
| Auth0 “Oops” + password form | Password DB must **not** be domain-level; email passwordless **must** be. Do not enable Username-Password for connector/web clients. |
| `the connection is not enabled` | Enable **email** connection for first-party connector apps (`Claude.ai MCP`, `steward_acs_mcp`) — setup script does this. |
| “Couldn't register with sign-in service” / Auth0 `too_many_entities` on `/oidc/register` | Free Auth0 tenants fill up with DCR apps. Prune with `python3 scripts/cleanup-auth0-dcr-clients.py --delete` (third-party only). Fixed DCR should prevent this. |
| Auth0 `cls` success then `fn` fail: Resend `domain is not verified` | Passwordless **From** and Branding → Email Provider **From** must use a Resend-verified domain (e.g. `noreply@stewardacs.xyz`), **not** an unverified org domain like `@safetyconnect.io`. Recipient can still be `@safetyconnect.io`. Fix: `AUTH0_EMAIL_FROM='Steward ACS <noreply@stewardacs.xyz>' python3 scripts/fix-auth0-email-from.py --fix` |
| “Couldn't register with sign-in service” | Enable **OIDC Dynamic Application Registration** or use manual Client ID from setup script |
| User logs in but no MCP tools | Assign **MCP User** role; **reconnect** connector for a fresh token with `permissions` |
| Claude: “Couldn't connect / Taking you back to the desktop app” after OTP | Auth0 login succeeded but ACS rejected the token. Check prod logs for `OAuth user is not authorized`. Common causes: (1) ACS user missing for that org; (2) **MCP User role missing `mcp:tools` on that tenant audience** (role had only `https://prod.stewardacs.xyz/mcp/sse` — run `scripts/ensure-auth0-org-audiences.sh` and attach role permissions per org API); (3) legacy Google vs email identity split. Reconnect after fixing so the connector gets a fresh token. |
| `setup-auth0.sh` / M2M `Unauthorized` | Refresh Management API M2M client secret in Auth0; update `certs/Oauth.md` / `AUTH0_M2M_*`. |

Verify ACS OAuth metadata:

```bash
curl -s https://prod.stewardacs.xyz/.well-known/oauth-protected-resource/mcp/sse
```

---

## Do not confuse with ACS developer keys

**Auth0 users** ≠ **`acs_dev_...` keys**.

- Generate developer keys from the ACS dashboard / Developers API for plugins and Claude Code.
- Auth0 users are only for **Connectors** OAuth on prod.
