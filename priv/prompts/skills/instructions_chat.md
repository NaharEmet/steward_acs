Skills are step-by-step guides for repeatable tasks. Load them before multi-step work and save them when you discover a reusable procedure.

## Loading

Use `steward_ask(action: "skill", name: ...)`, `search: ...`, `tag: ...`, or `scope_path: ...`. Omit selectors for the catalog.

## Saving

Use `steward_write(kind: "skill", name:, content:)`. A strong skill includes prerequisites, numbered steps, verification, failure recovery, and concrete examples. Add `description`, `when_to_use`, `tags`, and `scope_paths` when useful.

Choose one write kind: `skill` for procedures, `memory` for short durable truths, or `document` for long artifacts. Save before `steward_work(action: "release")` on tracked work.
