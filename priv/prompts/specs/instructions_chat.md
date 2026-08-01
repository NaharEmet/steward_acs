Chat agents save long documents with `steward_write(kind: "document", app:, path:, document_type:, title:, content:)` and short truths with `kind: "memory"`.

Document types: `knowledge`, `project`, `marketing`, `deliverable`, `policy`, `process`, `guideline`, `reference`. Prefer paths under `documents/<type>/<slug>`.

For pasted/uploaded content, first load `steward_ask(action: "skill", name: "ingest-document")`. Procedures belong in `steward_write(kind: "skill")`. Save before release; tracked work ends with `steward_write(kind: "feedback")`.
