---
name: "ingest-document"
description: Ingest a non-code document (policy, brief, marketing, knowledge) into Steward via documents_propose (chat) or specs_propose (coding)
when_to_use: When the user pastes, uploads, or asks to save a long document into ACS — not for code module specs (use ingest-spec) and not for short truths (use save_memory)
tags: ["ingest", "documents", "documents_propose", "knowledge", "chat"]
scope_paths:
  - documents
  - documents/policy
  - documents/project
  - documents/marketing
  - documents/knowledge
  - documents/deliverable
audit_reasoning: "The skill is highly actionable with clear, numbered steps, concrete tool names, and exact parameter examples. It includes prerequisites (clarifying artifact details), verification (confirming to user), and failure recovery (table of symptoms and fixes). The description is distinct and informative. The audience fit is excellent, as it explicitly differentiates between 'chat' and 'coding' surfaces with appropriate tool references. It is unique and not a duplicate of existing skills. The scope is well-defined and matches the domain."
audit_score: 10
audit_status: "ok"
audited_at: "2026-07-31T04:13:17.422748Z"
approved_at: "2026-07-31T04:13:17.439409Z"
approved_by: "llm"
reviewed_at: "2026-07-31T04:13:17.439409Z"
reviewed_by: "llm"
status: "approved"
---

# Ingest a document into Steward

Use this when the user has a **long non-code artifact** to keep in ACS (policy, project brief, marketing copy, research, process write-up).

Do **not** use this for:
- Short eternal truths → `save_memory`
- Step-by-step how-tos → `skill_save`
- Code module docs → skill `ingest-spec`

## Tools (chat vs coding)

| Surface | Retrieve first | Save |
|---------|----------------|------|
| **Chat** | `ask(content_query:)` | `documents_propose` |
| **Coding** | `ask` or `query_specs(query:)` | `specs_propose` |

## Steps

1. **Clarify the artifact**
   - Title (human-readable)
   - `document_type`: one of `knowledge` | `project` | `marketing` | `deliverable` | `policy` | `process` | `guideline` | `reference`
   - Org / app name (e.g. `safetyconnect`, `acme-corp`)
   - Business path under `documents/...` (e.g. `documents/policy/refunds`)

2. **Dedup before write**
   - Chat: `ask(content_query: "<title or topic>")`
   - Coding: `query_specs(query: "<title or topic>")`
   - If a close match exists, ask whether to update that path or create a new one.

3. **Normalize content to markdown**
   - Keep full body in `content`
   - Images as `![alt](url)` — do not invent URLs
   - Preserve structure (headings, lists, tables)

4. **Propose the document**

Chat:

```
documents_propose(
  app: "<org-or-app>",
  path: "documents/<type>/<slug>",
  document_type: "<type>",
  title: "<title>",
  content: "<full markdown>",
  source: "<optional file path or URL>",
  tags: ["..."],
  project: "<optional ABAC project>"
)
```

Coding (same store; tool name differs):

```
specs_propose(
  app: "<org-or-app>",
  path: "documents/<type>/<slug>",
  document_type: "<type>",
  title: "<title>",
  content: "<full markdown>",
  source: "<optional file path or URL>",
  tags: ["..."],
  project: "<optional ABAC project>"
)
```

5. **Confirm to the user**
   - Status will be `proposed` until approved
   - Tell them `app` + `path` so they can find it later
   - Optionally `save_memory` only if they also stated a durable rule (not the whole doc)

## Path examples

| Kind | path |
|------|------|
| Policy | `documents/policy/refunds` |
| Project brief | `documents/project/onboarding-brief` |
| Marketing | `documents/marketing/q3-launch-copy` |
| Knowledge | `documents/knowledge/billing-overview` |

## Failures

| Symptom | Fix |
|---------|-----|
| Tool missing | Chat surface must include `documents_propose` — reconnect connector / enable tool |
| Empty content rejected | Always pass full markdown in `content` for documents |
| Duplicate noise | Search with `ask` / `query_specs` first; update existing path when appropriate |
