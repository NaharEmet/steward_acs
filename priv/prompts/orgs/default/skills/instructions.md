Skills are reusable workflow guides — step-by-step know-how for repeatable tasks. USE WHEN: a task follows a known procedure (deploy, manage secrets, install, run tests) or you discover a repeatable pattern worth documenting for other agents.

## When to use skills vs memories vs specs/documents

- **skill_save** — procedural workflows with ordered steps (how to deploy, how to rotate secrets)
- **save_memory** — eternal truths and principles (invariants, pitfalls, decisions)
- **specs_propose** — **specs** for code modules, or **documents** for non-code artifacts (policy, marketing, briefs)

## Writing a good skill

1. **name** — short kebab-case identifier (e.g. `deployment`, `secrets-management`, `refund-playbook`)
2. **description** — one sentence: what this skill covers and when to use it (must differ from name)
3. **tags** — at least one tag for discovery (e.g. `["deployment", "ops"]`)
4. **scope_paths** — business domains and/or code paths this skill applies to (e.g. `["acme/support/refunds"]` or `["guides/deployment"]`)
5. **content** — markdown body with:
   - When to use this skill
   - Prerequisites
   - Numbered steps (commands, file paths, verification)
   - Common failures and how to recover

## Scope convention

Scopes are hierarchical labels for **org structure**, not only files:
- Business: `org/domain/topic` (e.g. `acme/sales/pricing`, `acme/support/refunds`)
- Code: module/path areas (e.g. `lib/acs/memory`)

Set `scope_paths` on each skill so agents entering that scope receive it in `relevant_skills` from `claim_work` or `generate_guidance_packet`.

## Examples of GOOD skills

- `deployment` — compares local vs org-memory deployment with compose files and verification steps
- `secrets-management` — how to use `pass`, what never to commit, rotation workflow
- `refund-playbook` — support refund steps scoped to `acme/support/refunds`

## Examples of BAD skills

- A single line like "see README" (not actionable)
- Duplicating a memory axiom without steps (use save_memory instead)
- Copy-pasting task-specific notes from one bug fix (not reusable)

## Tools

- `skill_get(name:)` — load one skill by name
- `skill_get(scope_path:)` — **list skills for a scope** (same paths as memories/specs)
- `skill_get(search:)` — search names, descriptions, tags, content
- `skill_get(tag:)` — filter by tag
- `skill_get()` — full catalog with `when_to_use` for every skill
- `skill_save(name, content, tags, description, scope_paths, when_to_use)` — create or update
- `skill_audit_status()` — run LLM quality audit on all skills
