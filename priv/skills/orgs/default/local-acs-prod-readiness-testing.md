---
description: "Run the isolated local production-like ACS test suite before promoting dev to prod."
name: "local-acs-prod-readiness-testing"
proposed_by: "nahar emet"
scope_paths: ["guides/deployment-testing", "scripts", "lib/acs/mcp", "test"]
status: "approved"
tags: ["acs", "testing", "deployment", "mcp", "release"]
when_to_use: "Before promoting Steward ACS dev to the multitenant prod deployment or after changing MCP, authorization, tenant storage, release, or smoke behavior."
audit_reasoning: "The skill is exceptionally well-structured and actionable. It provides a complete, step-by-step procedure with clear prerequisites, numbered actions, verification criteria, and failure recovery. The instructions are highly specific, referencing exact commands (e.g., `mix test`, `MIX_ENV=prod REPO_ADAPTER=postgres mix release`), tool names (MCP, Docker Compose), and configuration details. The audience ('coding') is perfectly matched, as the skill involves running tests, building releases, and inspecting logs—tasks suited for an IDE agent. The description is distinct and informative, and the skill is unique, focusing on a specific pre-promotion testing workflow not covered by existing skills."
audit_score: 10
audit_status: "ok"
audited_at: "2026-08-07T08:20:59.052824Z"
approved_at: "2026-08-07T08:20:59.059089Z"
approved_by: "llm"
reviewed_at: "2026-08-07T08:20:59.059089Z"
reviewed_by: "llm"
---

## When to use

Use this procedure before promoting the Steward ACS `dev` branch to the multi-tenant `prod` deployment, or after changing MCP tools, authorization, tenant storage, release configuration, or deploy smoke.

## Prerequisites

- Repository is on `dev`.
- Docker and Compose are available.
- No production database, Auth0, Infisical, Axiom, or production API key is present in the local fixture environment.
- A disposable Compose project name and test output directory are selected.

## Steps

1. Run focused tests for changed code, then run the fast contract suite: `mix test`, format check, compile with warnings as errors, and Credo.
2. Generate the tool inventory from the application registry. Compare core handler coverage, role/audience permissions, input schemas, and `CoreToolRoles.chat_surface/0`. Fail on missing handlers, duplicate names, invalid schemas, or unexpected chat tools.
3. Start a disposable production-like stack with an explicit Compose project, local Postgres, multitenant configuration, and isolated volumes. Never reuse the normal developer Compose project.
4. Wait for `/mcp/health`; if it fails, collect redacted container logs and stop. Do not proceed to tool tests against an unhealthy server.
5. Bootstrap two fixture organizations and separate developer credentials. Record only public fixture labels in test output.
6. Run live MCP protocol checks for coding and chat: connect, initialize, `tools/list`, validate inventory and schemas, call representative tools, assert structured errors, and close sessions.
7. Run workflow scenarios with unique run IDs: startup guidance, task lifecycle, memory/knowledge, skills, specs/documents, errors, diagnostics, dynamic tenant tools, malformed input, and negative authorization.
8. Run cross-tenant and credential-isolation checks. Verify both permitted same-tenant access and forbidden cross-tenant access, including tenant tools and internal-ID response rules.
9. Build/run the production release mode locally with `MIX_ENV=prod REPO_ADAPTER=postgres mix release`; repeat health, inventory, and representative workflow checks against that release.
10. Emit JSON and human-readable results containing commit/release identity, inventory hash, environment mode, and scenario outcomes. Redact keys, URLs with credentials, and database URLs.
11. Tear down only the disposable Compose project and volumes. Preserve failure logs and test results.
12. Promote only after all required gates pass and `dev` CI is green. A skipped live check is incomplete, not a pass.

## Verification

A successful run has no skipped required checks, a healthy release, matching coding/chat inventories, passing workflow and isolation scenarios, and retained machine-readable results. The post-deploy smoke must still run after cutover; local readiness does not replace deployed-host verification.

## Common failures and recovery

- If health fails, inspect container logs and environment resolution before retrying; do not use production secrets locally.
- If tool inventory differs, identify whether the registry, role map, chat surface, or running release is stale; fix the source-of-truth drift before promotion.
- If a protocol call is unauthorized, verify the fixture credential role, audience, and tenant context rather than weakening authorization.
- If a scenario leaves data behind, use the disposable database teardown and fix cleanup before treating the suite as reliable.
- If the release build fails while tests pass, treat it as a production-readiness failure and inspect `REPO_ADAPTER=postgres`, release config, migrations, and runtime environment.
