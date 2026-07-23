# Security and production-readiness audit

**Audit date:** 2026-07-22  
**Scope:** Elixir/Phoenix application, MCP transports and tools, tenant isolation, memory/spec persistence, authentication/authorization, outbound HTTP, concurrency/state stores, dependencies, CI, and deployment scripts.

## Release verdict

The application-level critical and high-severity findings discovered during this review are remediated in this branch and covered by regression tests. The code passes the full test suite, strict compilation, Credo, and Hex advisory audit.

Production deployment remains **conditional** until the operational items in “Remaining deployment risks” are completed. In particular, the canonical multi-tenant Compose topology still gives each Syncthing container access to the shared vault volume, and third-party container images are not pinned by digest. Do not describe a deployment as fully hardened until those controls are addressed and verified in the target environment.

## Remediated findings

| Severity | Finding | Remediation |
|---|---|---|
| Critical | Developer credentials could switch the execution organization for every tool, including mutation and key administration | Removed the capability from ordinary developer keys. Cross-org execution now requires an explicit permission and is restricted to an allowlist of read-only tools. Mutating/admin calls reject cross-org targets. |
| High | `query_specs` accepted traversal paths and could read or quarantine files outside the tenant root | App identifiers and paths are validated, expanded paths must remain inside the tenant root, symlink traversal is rejected, and query APIs return controlled errors. |
| High | OAuth bearer tokens without relevant scopes were treated as collaborators | OAuth scope mapping is fail-closed. Only explicit MCP scopes produce roles. Permission-protected tools now deny missing or malformed permission sets. |
| High | Collaborators could approve/reject specs | Approval and rejection tools are admin-only. |
| High | Custom YAML frontmatter allowed structure and duplicate-key injection | String keys, scalars, list items, and nested values are safely quoted and round-trip regression tests cover multiline injection payloads. |
| High | Indirect prompt injection could expose approved memory context and auto-approve/model-edit content | Other memories are no longer sent as evaluation context. Model recommendations are advisory; approve and reject recommendations require human review and cannot rewrite content or change final status automatically. |
| High | MCP rate-limit counters were owned by arbitrary request processes | A supervised owner now manages the ETS table and periodic cleanup; request counting remains atomic and concurrent. |
| High | Bridge authentication sessions had invalid ETS ownership and unbounded retention | A supervised, bounded session store now provides cross-process persistence, TTL eviction, and a hard session cap. |
| High | SSE unregister used a PID instead of a monitor reference and crashed the manager | Session entries retain monitor references and unregister/replacement/`DOWN` handling demonitor precisely. |
| High | Expired task leases were marked `done` | Expired claims return to `todo`, clear lease fields, release associated locks, and remain claimable. |
| High | SSRF checks missed mapped IPv6 and redirects | Non-public IPv4/IPv6 ranges, mapped/compatible addresses, unresolved hosts, and unsafe allowlist resolutions fail closed. Req redirects are disabled for bridge and app-auth calls. |
| High | Runtime app credentials/configuration were global across tenants | App configuration keys are organization-scoped. Bridge lookups use the authenticated org, and the global service key is not sent for non-default tenants. |
| High | Dashboard login lacked throttling | Login POSTs are rate-limited by client address and hashed identity with a `429`/`Retry-After` response. |
| High | JWT verification accepted any algorithm supported by a selected JWK | OAuth verification now requires `RS256` before key lookup/signature verification. |
| Medium | Request bodies had no explicit application cap | Endpoint parsers now enforce a 2 MB maximum. |
| Medium | Setup/deployment secret handling could disclose credentials | Secret prompts disable echo; scripts use `umask 077`, atomic writes, and mode `0600`; generated files explicitly warn against commits. |
| High | Optional Fluent Bit setup mounted the Docker socket | The socket and Docker metadata filter were removed. Fluent Bit reads only container log files. |
| High | Deploys could label a dirty build as a reviewed commit | Deploys refuse dirty working trees and publish/deploy only the commit-addressed tag, not the mutable `multitenant` tag. |
| High | Locked HTTP/framework packages had published advisories | Phoenix, Plug, Req, Mint, HPAX, and related dependencies were updated. Stale unused Hackney and related lock entries were removed. `mix hex.audit` is enforced in CI. |

## Verification performed

- `mix test` — **437 tests, 0 failures, 4 excluded** (excluded tests require an external Ollama service).
- `mix compile --warnings-as-errors` — passed.
- `mix credo --strict` — passed with no issues.
- `mix hex.audit` — no retired or advisory-affected locked packages.
- `mix deps.unlock --check-unused` — enforced in CI; unused lock entries were pruned.
- `git diff --check` — passed.
- Shell syntax checks for `bin/setup.sh`, `scripts/deploy.sh`, and `scripts/secrets-env.sh` — passed.
- Focused security regression suite — 107 tests, 0 failures before the final full-suite run.

Docker Compose validation could not be executed in the audit environment because the Docker CLI is not installed. It must be run in CI or on the deployment host before release.

## Remaining deployment risks

### High — Syncthing containers share the entire multi-tenant vault

All Syncthing services mount the same `vaults` volume and run their initialization as root. Compromise or misconfiguration of one instance can expose another tenant’s files.

**Required before a hardened multi-tenant release:** migrate each tenant to a distinct named volume (mounted into ACS at that tenant’s expected path), run Syncthing as an unprivileged UID/GID after provisioning, and test migration/rollback against a production backup. This needs an explicit data migration; changing volume declarations without migrating would risk data loss.

### High — Container supply chain is not immutable

Syncthing and Ollama use `latest`; other images and Dockerfile bases use mutable tags. The application deploy uses a commit-addressed tag but not a signed manifest digest.

**Required:** pin all images and build bases by digest, build from protected CI, generate an SBOM/provenance, sign with Cosign (or equivalent), verify before deployment, enable registry tag immutability, and retain a tested rollback digest. Add Trivy/Grype or an equivalent image/filesystem scan.

### Medium — DNS rebinding remains a network-layer concern

Outbound URLs are validated before Req opens the connection, so hostname validation and connection DNS resolution are separate operations. Tool definitions are admin-controlled and redirects are disabled, which reduces exploitability but does not eliminate DNS rebinding.

**Required:** enforce egress policy outside the process (deny loopback, link-local, RFC1918/ULA, metadata, and internal service networks), restrict bridge hostnames with `BRIDGE_ALLOWED_HOSTS`, and consider a resolving egress proxy that pins the validated destination.

### Medium — Login throttling is node-local

The supervised ETS limiter is appropriate for a single node. A multi-node deployment needs a shared limiter, and the reverse proxy must provide a trustworthy client-address boundary. Tune limits to avoid account-specific denial of service.

### Operational verification still required

- Run `docker compose -f docker-compose.multitenant.yml config` with the production environment.
- Verify secret-file ownership/modes, TLS, database transport, host firewall, Auth0 tenant settings, and trusted proxy behavior on the actual host.
- Perform and document a full backup restore drill.
- Validate externally mounted MCP YAML definitions and synchronized vault contents; they were not available to the static audit.
- Add secret scanning and container/SBOM scanning to protected CI.

## Maintenance guidance

- Keep authorization context server-injected; never trust `_auth_*` fields from tool arguments.
- Any future cross-org capability must use an explicit platform permission and a read-only allowlist.
- Treat LLM output and synchronized Markdown/YAML as untrusted input. Models may recommend but must not authorize or mutate server-owned security metadata.
- Keep outbound requests on the centralized URL-safety path with redirects disabled.
- Put mutable shared state under supervised ownership and test cross-process lifecycle behavior.
- Run tests, strict compilation, Credo, Hex audit, secret scanning, and image scanning for every release.
