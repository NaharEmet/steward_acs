Skills are reusable step-by-step workflows for repeatable tasks. USE WHEN: you followed a multi-step procedure another agent should re-run (deploy, secrets, testing, support, MCP sequences, debug playbooks, ingest, review) — not a one-off patch note.

## Before multi-step work

```
skill_get(name: "deployment")        # exact name
skill_get(scope_path: "ops/backup")  # list skills for a domain
skill_get(search: "secrets")         # keyword across names/descriptions/tags
skill_get(tag: "deployment")         # filter by tag
skill_get()                          # full catalog with when_to_use
```

## When to save

| Store | When | Example |
|-------|------|---------|
| **skill_save** | Repeatable procedure | How to deploy, rotate keys, upsert an Axiom dashboard |
| **save_memory** | Eternal truth, principle | "LiveViews need catch-all handle_info" |
| **specs_propose** (document) | Long non-code artifact | Policy, brief, research — document_type + content |
| **specs_propose** (spec) | Code module docs | purpose/invariants for a module |

## Writing a good skill

- **name** — kebab-case: `deployment`, `secrets-management`, `refund-playbook`
- **description** — one sentence distinct from name and content
- **tags** — at least one: `["deployment", "ops"]`
- **scope_paths** — business domains or code paths: `["acme/support/refunds"]`
- **content** — must include:
  - When to use this skill
  - Prerequisites (exact tools, access, files)
  - Numbered steps with concrete commands, file paths, tool calls
  - Verification (how to confirm it worked)
  - Failure recovery (what to do when a step fails)

## Guidelines for good content

- Use exact file paths and command examples — don't make the agent guess
- Include the EXACT tool name and parameters where relevant (e.g. `skill_get(name: "deployment")`)
- Number each step sequentially
- Preface each section with a header (`## Steps`, `## Verification`, etc.)
- For failure modes, be specific: "If X fails, check Y, then try Z"

## Bad skills to avoid

- "See README" (not actionable)
- Copy-pasted memory axioms (use `save_memory` instead)
- Single-bug patch notes (not reusable)
- No numbered steps (just paragraphs of prose)
- Missing prerequisites section
- Vague content: "replace with your values" without saying what goes where
- Description that is identical to the name or the first line of content
- Scope too broad (covers multiple unrelated procedures in one skill)
- No verification step — agent can't confirm success

## Tools

- `skill_get(name:)` / `skill_get(scope_path:)` / `skill_get(search:)` / `skill_get(tag:)` / `skill_get()`
- `skill_save(name, content, tags, description, scope_paths, when_to_use)`
- `skill_audit_status()` — run LLM quality audit on all skills
