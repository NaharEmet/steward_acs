Skills are step-by-step guides for repeatable tasks. Load them before multi-step work and save them when you discover a useful procedure.

## Loading skills

- `skill_get(name: "deployment")` — load one skill by name
- `skill_get(scope_path: "acme/support")` — list skills for a domain
- `skill_get(search: "deploy database")` — keyword search
- `skill_get()` — full catalog of all skills

## Saving skills

Call `skill_save` when you walk through a repeatable procedure:

```
skill_save(
  name: "my-workflow",
  description: "What this covers (one sentence, differs from name)",
  tags: ["deployment", "ops"],
  scope_paths: ["acme/ops"],
  content: "## When to use\n…\n## Prerequisites\n…\n## Steps\n1. …\n## Verification\n…\n## Failure recovery\n…"
)
```

## What to store where

- **skill_save** — step-by-step procedures
- **save_memory** — short eternal truths (principles, decisions, invariants)
- **documents_propose** — long documents (policies, briefs, research, reports)

Skills are short, actionable, and reusable. If it has numbered steps, it belongs in a skill.
