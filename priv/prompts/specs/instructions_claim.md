specs_propose = one store, two kinds.

SPEC (code): why a module exists — purpose, invariants, workflows. USE WHEN a code module's intent or contract changed.

DOCUMENT (non-code): long shareable artifact — document_type + title + content under documents/<type>/<slug>. USE WHEN keeping policy/brief/research/marketing/knowledge.

Decide what to save when a task is done — pick the first trigger that applies:

1. **Worked out a plan with the user** (implementation, improvement, migration, remediation) → `specs_propose` a **document** under `documents/plans/<slug>` so the plan persists.
2. **Changed a code module's intent/contract** → `specs_propose` a **spec** for that module path. Check `query_specs(undocumented: true)` first.
3. **Followed a repeatable multi-step procedure** → `skill_save`.
4. **Produced a long shareable artifact** → `specs_propose` a **document**.
5. **Discovered a short eternal truth** → `save_memory`.
6. **Otherwise** → save nothing; do not force a save.

Example triggers:
- Agreed a rollout plan for prod migration → `specs_propose` a plan document.
- Re-designed how tasks are claimed → `specs_propose` a spec for the claiming module.
- Long policy/brief drafted with the user → `specs_propose` a document.
- One-off note → nothing.

Before `release_work`, self-check:
- Worked out a plan with the user? → save it as a document.
- Module intent changed? → `specs_propose` a spec.
- Repeatable procedure just run? → `skill_save`.
- `query_specs(undocumented: true)` shows the module you touched is missing a spec? → write one.

Not for short truths (save_memory) or how-tos (skill_save). query_specs searches both. Save before release_work.
