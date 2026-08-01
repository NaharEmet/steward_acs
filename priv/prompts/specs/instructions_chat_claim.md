`steward_write(kind: "document")` saves long non-code artifacts via app + path + document_type + title + content. Prefer paths under documents/<type>/<slug>.

Use when the user pastes/uploads a document or you produce long shareable text. Not for short truths (`kind: "memory"`) or procedures (`kind: "skill"`). Load `steward_ask(action: "skill", name: "ingest-document")` first. Save before release.
