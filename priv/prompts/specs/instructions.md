One store, two kinds:

| Kind | When | How to save |
|------|------|-------------|
| **Spec** (code) | Why a code module exists | `purpose`, `invariants`, `workflows`, `failure_modes`, `constraints` — or `document_type: "spec"` |
| **Document** (non-code) | Anything to keep/share | `document_type` + `title` + `content` (markdown) |

## What belongs where

| Store | What | Example |
|-------|------|---------|
| **specs** (code) | Module documentation | Purpose/invariants for `Acs.Memory.Guidance` |
| **documents** (non-code) | Long shareable artifacts | Project briefs, marketing copy, policies, research |
| **skills** | Step-by-step procedures | How to deploy, run a refund |
| **memories** | Eternal truths | Invariants, decisions, patterns |

## Document types (non-code)

`knowledge`, `project`, `marketing`, `deliverable`, `policy`, `process`, `guideline`, `reference`

Required: `document_type`, `title`, `content`. Optional: `source`, `project`, `tags`.

## When code and a spec disagree

1. Pause  2. Identify the diff  3. Ask the user which to update  4. Never assume one is wrong

## When to call specs_propose

- After implementing or changing a module → save a **spec**
- After producing a document the user wants to keep → save a **document**
- At task finish (`release_work` flow), before `submit_task_feedback`

## Tools

- `specs_get(app, path)` — read one spec or document
- `query_specs(query:)` — search both specs and documents
- `query_specs(undocumented: true)` — find modules missing specs
- `specs_propose(app, path, ...)` — create or update (status → proposed)
- `specs_approve(app, path, reviewer)` / `specs_reject(app, path)`
