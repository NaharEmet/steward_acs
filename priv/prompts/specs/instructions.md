Specs are the **document store** — anything produced during work that should be saved and shared. Not just code module docs.

## What belongs in specs (vs skills vs memories)

| System | What to store | Examples |
|--------|---------------|----------|
| **specs** | Long documents & artifacts to share | Module specs, architecture write-ups, project briefs, marketing copy, reports, deliverables with image links |
| **skills** | Short repeatable **procedures** (step-by-step) | How to deploy, how to run migrations |
| **memories** | Short **eternal truths** (principles) | Invariants, pitfalls, decisions that stay true forever |

## Two spec modes

### 1. Module spec (code work)

Use when documenting **why code exists**. Structured fields:

- `purpose`, `invariants`, `workflows`, `failure_modes`, `constraints`, `tags`
- Or `document_type: "spec"` with full `content` markdown for long module write-ups

`query_specs(undocumented: true)` finds modules missing specs.

### 2. Document (any shareable output)

Use when the user or agent produced a **document** to keep or share:

- **knowledge** — long knowledge files about systems, architecture, research
- **project** — project plans, briefs, status docs, client deliverables
- **marketing** — copy, campaigns, landing page text (embed images as `![alt](url)` in markdown)
- **deliverable** — any other output the user wants preserved
- **policy / process / guideline / reference** — org knowledge documents

Required: `document_type`, `title`, `content` (full markdown). Optional: `source` (file path or asset URL), `project`, `tags`.

Path examples:
- Code: `app: steward_acs`, `path: acs/memory/guidance`
- Project doc: `app: acme-corp`, `path: documents/project/onboarding-brief`
- Marketing: `app: acme-corp`, `path: documents/marketing/q3-launch-copy`

## When code and a module spec disagree

1. Pause  2. Identify the diff  3. Ask the user which to update  4. Never assume one is wrong

## When to call specs_propose

- After implementing or changing a **module** (module spec)
- After producing **any document** the user wants saved or shared (document mode)
- At task finish (`release_work` flow), before `submit_task_feedback`

## Tools

- `specs_get(app, path)` — read one entry
- `query_specs(query:)` — search all specs and documents
- `query_specs(undocumented: true)` — modules missing code specs only
- `specs_propose(app, path, ...)` — create or update (status → proposed)
- `specs_approve(app, path, reviewer)` / `specs_reject(app, path)`
