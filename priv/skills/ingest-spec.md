---
name: ingest-spec
description: Ingest a code module spec into Steward (purpose, invariants, workflows) via specs_propose
when_to_use: When documenting why a code module exists, filling undocumented modules, or turning a design note into a module spec — not for policies/briefs (use ingest-document)
tags: ["ingest", "specs", "code", "module", "specs_propose"]
scope_paths:
  - specs
  - lib
  - agent_coordination_system
---

# Ingest a code module spec into Steward

Use this when saving **code module documentation** — why the module exists, invariants, workflows, failure modes.

Do **not** use this for:
- Non-code documents (policy, marketing, briefs) → skill `ingest-document`
- Short truths → `save_memory`
- Procedures → `skill_save`

## Tools

| Step | Chat | Coding |
|------|------|--------|
| Find gaps / prior art | `ask(content_query:)` | `query_specs(undocumented: true)` or `query_specs(query:)` |
| Read existing | (via ask results) | `specs_get(app, path)` |
| Save | `specs_propose` | `specs_propose` |

## Steps

1. **Identify the module**
   - `app` — codebase / app name (e.g. `steward_acs`)
   - `path` — module path without extension (e.g. `acs/memory/guidance`)
   - Confirm with the user if ambiguous

2. **Check what already exists**
   - Coding: `specs_get(app, path)` and/or `query_specs(undocumented: true)`
   - Chat: `ask(content_query: "<module name> spec")`
   - If a proposed/approved entry exists, update it rather than inventing a parallel path

3. **Extract structured fields from the source**
   Prefer structured module-spec fields when you can derive them:

   | Field | Meaning |
   |-------|---------|
   | `purpose` | Why this module exists |
   | `invariants` | Truths that must always hold |
   | `workflows` | Expected call sequences |
   | `failure_modes` | Known failures and handling |
   | `constraints` | Non-goals / limits |
   | `tags` | Search tags |

   For a long write-up, you may instead use `document_type: "spec"` + full markdown `content`.

4. **Propose the spec**

Structured form:

```
specs_propose(
  app: "<app>",
  path: "<module/path>",
  purpose: "...",
  invariants: ["..."],
  workflows: ["..."],
  failure_modes: ["..."],
  constraints: ["..."],
  tags: ["..."]
)
```

Long-form form:

```
specs_propose(
  app: "<app>",
  path: "<module/path>",
  document_type: "spec",
  title: "<Module name>",
  content: "<full markdown>"
)
```

5. **Code vs spec disagreement**
   If the code and an existing spec disagree: pause, name the diff, ask the user which to update. Never assume one is wrong.

6. **Confirm**
   - Entry is `proposed` until approved
   - Report `app` + `path`

## Path examples

| Module | app | path |
|--------|-----|------|
| Guidance | `steward_acs` | `acs/memory/guidance` |
| Tool registry | `steward_acs` | `acs/mcp/tool_registry` |

## Failures

| Symptom | Fix |
|---------|-----|
| Wrong kind saved as document | Use `ingest-document` for non-code; keep module paths under the app, not `documents/...` |
| Undocumented still lists module | Spec may still be `proposed` — needs `specs_approve` (admin) |
| Thin one-line purpose | Expand invariants/workflows; a useful spec answers “what must never break?” |
