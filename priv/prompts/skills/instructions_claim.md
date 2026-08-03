Skills = step-by-step how-tos (prerequisites, numbered steps, verification, failure recovery).

Decide what to save when a task is done — pick the first trigger that applies:

1. **Worked out a plan with the user** (implementation, improvement, migration, remediation) → `specs_propose` a **document** under `documents/plans/<slug>` so the plan persists (document_type + title + content).
2. **Changed a code module's intent/contract** → `specs_propose` a **spec** (purpose, invariants, workflows) for that module path. Check `query_specs(undocumented: true)` first.
3. **Followed a repeatable multi-step procedure** (deploy, secrets rotation, ingest, MCP/debug playbook, review, support) → `skill_save`.
4. **Produced a long shareable artifact** (policy, brief, research, marketing) → `specs_propose` a **document**.
5. **Discovered a short eternal truth** → `save_memory`.
6. **Otherwise** → save nothing; do not force a save.

Example triggers:
- Ran `bin/setup.sh` end-to-end → `skill_save` the installer walkthrough.
- Re-designed how tasks are claimed → `specs_propose` a spec for the claiming module.
- Agreed a rollout plan for prod migration → `specs_propose` a plan document.
- One-off bug fix → nothing (or a memory if a reusable lesson emerged).

Before `release_work`, self-check:
- Worked out a plan with the user? → save it as a document.
- Module intent changed? → `specs_propose` a spec.
- Repeatable procedure just run? → `skill_save`.
- `query_specs(undocumented: true)` shows the module you touched is missing a spec? → write one.

`skill_get` before procedural work; `skill_save` before `release_work`.
