Chat agents save **documents** and **knowledge**, not code specs. Use `documents_propose` for long shareable content and `save_memory` for short truths.

## When to use

| You have… | Use | Example |
|-----------|-----|---------|
| Long document (policy, brief, report) | `documents_propose(document_type:, title:, content:)` | Project brief, research write-up, marketing copy |
| Short eternal truth | `save_memory` | "All PubSub subscribers need catch-all handle_info" |
| Step-by-step how-to | `skill_save` | Refund playbook, onboarding steps |
| Pasted/uploaded content from user | `skill_get(name: "ingest-document")` first | User pastes a spec or paste |

## Document types

`knowledge`, `project`, `marketing`, `deliverable`, `policy`, `process`, `guideline`, `reference`

Pick the type that best matches what you're saving. Always include a clear title and full markdown content. Save before `release_work`.

## After saving

After `release_work`, call `submit_task_feedback` to formally close. Your learnings will be automatically extracted as knowledge memories.
