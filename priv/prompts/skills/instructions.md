Skills are reusable step-by-step workflows for repeatable tasks (deployment, secrets, testing, support). Load them before multi-step work and save them when you discover a repeatable pattern.

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
| **skill_save** | Repeatable procedure | How to deploy, rotate keys, run a refund |
| **save_memory** | Eternal truth, principle | "LiveViews need catch-all handle_info" |
| **specs_propose** | Module docs or long docs | Why a module exists, project brief |

## Writing a good skill

- **name** — kebab-case: `deployment`, `secrets-management`, `refund-playbook`
- **description** — one sentence distinct from name and content
- **tags** — at least one: `["deployment", "ops"]`
- **scope_paths** — business domains or code paths: `["acme/support/refunds"]`
- **content** — when to use, prerequisites, numbered steps, verification, failure recovery

## Bad skills to avoid

- "See README" (not actionable)
- Copy-pasted memory axioms (use `save_memory` instead)
- Single-bug patch notes (not reusable)

## Tools

- `skill_get(name:)` / `skill_get(scope_path:)` / `skill_get(search:)` / `skill_get(tag:)` / `skill_get()`
- `skill_save(name, content, tags, description, scope_paths, when_to_use)`
- `skill_audit_status()` — run LLM quality audit on all skills
