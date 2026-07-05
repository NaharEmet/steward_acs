---
name: acs-memory-cleanup
description: "Identify and clean up ACS Agent Knowledge Memory — duplicates, noise, test data, stale entries, and conflicts. Use when memory system has quality issues, duplicate ID errors, or too many low-quality auto-generated memories."
---

Steward ACS Agent Knowledge Memory cleanup skill. Targets the YAML + SQLite memory system under `apps/steward_acs/priv/acs_memory/`, NOT the Anantha business domain memory pipeline (Claims, Records, etc.).

## The Two Memory Systems — Know the Difference

| Aspect | ACS Agent Knowledge Memory (THIS) | Anantha Business Domain Memory |
|--------|-----------------------------------|-------------------------------|
| Purpose | Agent guidance, learnings, patterns | Business data extraction |
| Storage | YAML + SQLite | Postgres Ecto schemas |
| Tools | `query_memories`, `set_memory_status`, `save_memory` | `acs_ant_*` search/get tools |
| Pipeline | Manual save + periodic Auditor eval | Automated extraction pipeline |
| Kinds | observation, learning, warning, pattern, bug, decision, invariant, axiom | claims, records, observations, sentiments |

**Never mix these up.** This skill handles only the ACS knowledge memory.

## Memory Anatomy — Quick Reference

| Field | Purpose |
|-------|---------|
| `id` | Deterministic: `kind` + title_slug + scope_hash |
| `kind` | One of 8 kinds (see above) |
| `status` | proposed → approved/rejected → stale → deprecated/archived |
| `scope_path` | Namespace for grouping (e.g. `agent_coordination_system/cache`) |
| `importance` | 1-5, higher = more critical |
| `content` | Full markdown body |
| `created_by` | Agent or system that created it |

## Common Memory Problems

### 1. Duplicate ID Errors

`"A memory with the same ID already exists"` — caused by calling `save_memory` with same kind+title+scope_path.

**Detection:**
- Check `save_memory` errors for the exact ID
- Search for memories with same title+scope to find existing copies
- Look in Auditor logs for duplicate warnings

**Fix:**
```elixir
# Before saving, always check:
query_memories(query: "exact title", scope_path: "same/scope")
query_memories(scope_path: "same/scope", kind: "same_kind")
# If exists, use set_memory_status to update or skip
```

### 2. Low-Quality Auto-Generated Task Feedback

Task feedback templates: "Key learning from task", "Issue encountered in task", "Improvement suggestion" — generic content with no real signal.

**Detection:**
```
query_memories(scope_path: "", kind: "learning")
query_memories(scope_path: "", kind: "observation")
```
Then grep content for these template prefixes.

**Auditor pre-filter patterns** (these are auto-rejected by the Auditor):
- Title starts with "Key learning from task"
- Title starts with "Issue encountered in task"
- Title starts with "Improvement suggestion"
- `title == content` (no added value)
- `content` length < 20 characters

**Fix:**
```
set_memory_status(memory_id: "<id>", status: "rejected", notes: "Auto-generated task feedback, no signal")
```

### 3. Test / Harness Data Leaking In

Memories from test runs with no real knowledge value.

**Detection — scope patterns (auto-rejected by Auditor):**
- `scope_path` starts with `test/` or `test_app/`

**Detection — ID patterns:**
- ID contains `lifecycle_rebuild`
- ID contains `guidance_test`
- ID contains `e2e_pipeline`
- ID contains `test_hybrid`

**Fix:**
```
query_memories(scope_path: "test/")
query_memories(scope_path: "test_app/")
# Then reject each:
set_memory_status(memory_id: "<id>", status: "rejected", notes: "Test/harness data")
```

### 4. Trivial or Empty Memories

No useful content — noise that degrades retrieval quality.

**Detection:**
- `scope_path` is empty string
- `title == content` (no elaboration)
- `content` length < 20 characters
- `importance` == 1 (lowest)
- Empty `tags` array

**Fix:**
```
query_memories(scope_path: "")
# Review each — some may be valid system-level memories
set_memory_status(memory_id: "<id>", status: "rejected", notes: "Empty scope / trivial content")
```

### 5. Fuzzy Duplicates

Same knowledge saved multiple times with slightly different titles. The Auditor detects these via Jaro-Winkler similarity > 0.85.

**Detection:** Use `query_memories(query: "topic")` to find similar entries. Manual inspection required — the fuzzy check is only in the Auditor, not exposed as a tool.

**Fix:** Keep the best version (highest importance, most complete content), reject the rest:
```
set_memory_status(memory_id: "<keep_id>", status: "approved")
set_memory_status(memory_id: "<dup_id>", status: "rejected", notes: "Fuzzy duplicate of <keep_id>")
```

### 6. Stale / Deprecated Memories

Memories that are no longer accurate or relevant.

**Detection:**
```
query_memories(kind: "axiom", status: "approved")
query_memories(kind: "invariant", status: "approved")
# Check `updated_at` — if old and knowledge has changed
```

**Fix:**
```
# Mark outdated
set_memory_status(memory_id: "<id>", status: "stale", notes: "Outdated — refer to newer memory <new_id>")
# Or if completely obsolete:
set_memory_status(memory_id: "<id>", status: "deprecated", notes: "No longer applicable — replaced by <new_id>")
```

### 7. Conflicting Memories

Tag overlap >= 3 at same scope with contradictory guidance.

**Detection (via conflict.ex logic):**
- Two memories at same `scope_path` with 3+ overlapping `tags`
- `confidence` is "high" if overlap >= 4
- Manual review needed to determine which is correct

**Fix:** Keep the accurate version, deprecate the incorrect one:
```
set_memory_status(memory_id: "<correct_id>", status: "approved", notes: "Verified correct")
set_memory_status(memory_id: "<wrong_id>", status: "stale", notes: "Contradicts <correct_id>")
```

## Status Flow Reference

```
proposed → approved → stale → deprecated → archived
proposed → rejected → (terminal)
proposed → stale → deprecated → archived
```

- **proposed**: Awaiting review
- **approved**: Active, visible to agents via `generate_guidance_packet`
- **rejected**: Terminal — wrong, noise, or test data
- **stale**: Previously approved but outdated — needs review
- **deprecated**: No longer applicable but kept for history
- **archived**: Permanently stored but excluded from queries
- **parse_error**: YAML parsing failure (rare, requires YAML fix)

## Cleanup Workflow

### Quick Scan (5 min)
```
1. memory_health_check() → check overall health
2. query_memories(kind: "learning", status: "proposed") → find unapproved
3. query_memories(status: "stale") → find outdated
4. Check for obvious noise (templates, test data)
```

### Deep Clean (30 min)
```
1. Scan ALL proposed → approve signal, reject noise
2. Scan stale → deprecate or archive if confirmed obsolete
3. Search for duplicates by topic
4. Verify no test/harness data remains
5. memory_health_check() → verify improvement
```

### Full Audit (2+ hours)
```
1. Every memory reviewed
2. Conflicts resolved
3. Status flow completed for all entries
4. YAML files checked for parse errors
5. Health check score > 90%
```

## YAML File Cleanup (Advanced)

For complete removal (beyond status changes), manage YAML files directly:

```
apps/steward_acs/priv/acs_memory/<scope_path>.yaml
```

Where `<scope_path>` matches the memory's `scope_path` field (e.g. `elixir/testing`, `phoenix/routing`, `test_app/rebuild`).

- Remove the YAML file to permanently delete
- After removal, trigger: `acs_refresh_tools()` to reload memory index — this rebuilds the SQLite index from YAML files
- OR restart the ACS process to rebuild SQLite index

**WARNING:** Only do this after verifying the memory is safe to delete. Prefer `set_memory_status` to `rejected`/`deprecated`/`archived` whenever possible — status changes are reversible, file deletion is not.

## Safety Rules

1. **Never bulk-reject without reviewing** — context matters. A "Key learning" might contain real signal despite its template title.
2. **Prefer status over deletion** — `rejected`/`deprecated`/`archived` are reversible. YAML file deletion is not.
3. **Check `created_by`** — don't reject another agent's legitimate learning without understanding its value.
4. **Document mass cleanups** — save a memory explaining what was cleaned and why:
   ```
   save_memory(kind: "observation", title: "Memory cleanup YYYY-MM-DD", ...)
   ```
5. **Run health check before and after** — verify improvement:
   ```
   memory_health_check()  # before
   # ... cleanup ...
   memory_health_check()  # after — score should be higher
   ```

## Eval Queries

### Eval: Duplicate check
```
Search for memories with duplicate titles at the same scope_path. Verify no two approved memories say the same thing differently.
```

### Eval: Noise ratio
```
Calculate the ratio of rejected+stale to total memories. Target: <10% stale, <5% noise (rejected test data / templates).
```

### Eval: Status hygiene
```
Verify all memories have progressed beyond 'proposed' status within 7 days. Flag any proposed memories older than 30 days for immediate review.
```

### Eval: Conflict resolution
```
Identify memory pairs with >=3 overlapping tags at the same scope_path. Verify no approved pair contains contradictory guidance.
```
