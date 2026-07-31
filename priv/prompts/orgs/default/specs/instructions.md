# Specs & Documents

One store, two kinds:

| Kind | When | How to save |
|------|------|-------------|
| **Spec** (code) | Documenting **why a code module exists** | Structured fields: `purpose`, `invariants`, `workflows`, `failure_modes`, `constraints` — or `document_type: "spec"` + markdown `content` |
| **Document** (non-code) | Anything outside code to keep/share | `document_type` + `title` + `content` (full markdown) |

Tools are still named `specs_*` (compatibility). Treat them as **specs for code** and **documents for everything else**.

## What belongs where

| System | What to store | Examples |
|--------|---------------|----------|
| **specs** (code) | Module documentation | purpose, invariants, failure modes for `Acs.Memory.Guidance` |
| **documents** (non-code) | Long shareable artifacts | project briefs, marketing copy, policies, reports, research |
| **skills** | Short repeatable **procedures** | How to deploy, how to run a refund |
| **memories** | Short **eternal truths** | Invariants, pitfalls, decisions that stay true forever |

## Document types (non-code)

- **knowledge** — long knowledge files about systems, architecture, research
- **project** — project plans, briefs, status docs, client deliverables
- **marketing** — copy, campaigns, landing page text (embed images as `![alt](url)` in markdown)
- **deliverable** — any other output the user wants preserved
- **policy / process / guideline / reference** — org knowledge documents

Required for documents: `document_type`, `title`, `content`. Optional: `source`, `project`, `tags`.

## Scope convention (org knowledge structure)

Hierarchical labels for **how the org is structured**:

- Code specs: `app: steward_acs`, `path: acs/memory/guidance`
- Business documents: `app: acme-corp`, `path: documents/policy/refunds`
- Business scopes on memories/skills: `acme/sales/pricing`, `acme/support/refunds`

## When code and a module spec disagree

1. Pause  2. Identify the diff  3. Ask the user which to update  4. Never assume one is wrong

## When to call `specs_propose`

- After implementing or changing a **module** → save a **spec** (purpose / invariants / workflows)
- After producing **any non-code document** to keep → save a **document** (`document_type` + `title` + `content` under `documents/<type>/<slug>`)
- Before `release_work` (then `submit_task_feedback` last)

Not for short truths (`save_memory`) or step-by-step how-tos (`skill_save`).

## Tools

- `specs_get(app, path)` — read one **spec** or **document**
- `query_specs(query:)` — search both specs and documents
- `query_specs(undocumented: true)` — code modules missing **specs** only
- `specs_propose(app, path, ...)` — create or update (status → proposed)
- `specs_approve(app, path, reviewer)` / `specs_reject(app, path)`
