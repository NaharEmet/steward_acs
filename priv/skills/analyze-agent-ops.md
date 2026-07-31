---
description: Query Steward agent.tool / agent.feedback usage in Axiom (Claude vs coding)
name: "analyze-agent-ops"
scope_paths: ["lib/acs/observability", "lib/acs/meta_harness", "guides/deployment"]
when_to_use: When analyzing how Claude or coding agents use Steward — what works, gaps, misuse, unplanned wins
tags: ["axiom", "telemetry", "claude", "analytics", "agent-ops"]
---

# Analyze agent usage (Axiom)

Dataset **`steward_meta_analytics`** (`AXIOM_AGENT_OPS_DATASET`). Mirrored to `steward_logs` as backup. **One dataset** for live tool calls + hourly Meta-Harness rollups.

| `message` | Meaning |
|-----------|---------|
| `agent.tool` | One MCP tool call |
| `agent.tools_list` | One MCP `tools/list` inventory (what schemas were advertised) |
| `agent.feedback` | Task feedback close |
| `meta.summary` | Hourly rollup (totals, success_rate) |
| `meta.tool` | Per-tool reliability + latency |
| `meta.error_cluster` | Grouped failures |
| `meta.intake` | save_memory/skill_save intake gates (prompt-tuning) |
| `meta.agent` | Per-agent behavior |

Dashboard: `./scripts/axiom-upsert-agent-ops-dashboard.sh` → **Steward ACS — agent usage**.

Prod: `META_HARNESS_ENABLED=true` buffers `acs_tool_operations` and ships hourly `meta.*` into the same dataset.

### `agent.tools_list` fields

| Field | Meaning |
|-------|---------|
| `audience` | `chat` or `coding` |
| `audience_source` | `url` (SSE path / `?audience=`) or `client_info` |
| `client_name` | MCP `clientInfo.name` (Claude vs GPT vs Cursor, etc.) |
| `client_version` | MCP `clientInfo.version` |
| `mcp_endpoint` | e.g. `/mcp/chat/sse` |
| `role` / `org` | Auth context |
| `tool_count` | Number of schemas returned |
| `tool_names` | Sorted name list |
| `tools_hash` | sha256 of sorted names joined by newline (cheap equality) |

Claude.ai and ChatGPT share the **chat** surface on `/mcp/chat/sse` — vendors are not different tool sets. Use `client_name` only to split traffic after you know `audience`/`mcp_endpoint` are correct.

Deploy smoke (optional): set GitHub Environment / env `SMOKE_API_KEY` → `scripts/smoke-chat-tools.sh` asserts chat `tools/list` equals live `CoreToolRoles.chat_surface/0`. See `guides/deployment.md`.

## Learning signals (`signal` on agent.tool / agent.feedback)

| `signal` | Quadrant | Meaning | Action |
|----------|----------|---------|--------|
| `works` | Planned + good | Retrieve hits or clean writes | Keep / amplify patterns |
| `win` | Unplanned + good | Feedback `learned_for_agents` filled | Promote into memories/skills |
| `surprise_persist` | Unplanned + good? | Write after empty retrieve | Audit: real gap-fill vs invent |
| `gap_empty` | Planned missing | Retrieve returned 0 | Seed knowledge / fix scopes |
| `gap_info` | Planned missing | Feedback `info_needed` | Same — backlog for content |
| `pain` | Broken | Feedback issues/improvements | Fix tools/prompts |
| `intake_gate` | Friction | save blocked for clarification | Raise allow bar in Settings → Prompts (`memory/intake`, `skills/intake`) |
| `intake_bypass` | Friction? | `intake_confirmed` after a gate | False positives → loosen prompt |
| `misuse_discovery` | Shouldn't | Unknown tool name | Prompt/tool-list clarity |
| `misuse_write` | Shouldn't | Write with no prior retrieve in chain | Nudge retrieve-first UX |

## APL starters

### Signal mix

```apl
['steward_meta_analytics']
| where isnotnull(signal)
| summarize n=count() by signal, audience
| order by n desc
```

### Intake gates (Claude slowdown)

```apl
['steward_meta_analytics']
| where message == "agent.tool" and signal in ("intake_gate", "intake_bypass")
| summarize n=count() by tool_name, signal, intake_outcome, intake_source, audience, org
| order by n desc
```

### Meta intake rollup (hourly)

```apl
['steward_meta_analytics']
| where message == "meta.intake"
| project _time, tool_name, error_type, occurrence_count, prompt_hint
| order by occurrence_count desc
| limit 40
```

### Meta-Harness hourly health

```apl
['steward_meta_analytics']
| where message == "meta.summary"
| project _time, total_ops, success_rate, failure_count, discovery_count, intake_gate_count, active_agents
| order by _time desc
| limit 24
```

### Worst tools (from rollup)

```apl
['steward_meta_analytics']
| where message == "meta.tool"
| summarize avg_fail=avg(failure_count), avg_sr=avg(success_rate), n=count() by tool_name
| order by avg_fail desc
| limit 20
```

### Error clusters

```apl
['steward_meta_analytics']
| where message == "meta.error_cluster"
| project _time, tool_name, error_type, occurrence_count, sample_message
| order by occurrence_count desc
| limit 40
```

### Gaps — empty knowledge by scope

```apl
['steward_meta_analytics']
| where message == "agent.tool" and signal == "gap_empty"
| summarize n=count() by scope_path, tool_name, audience, org
| order by n desc
```

### Unplanned wins

```apl
['steward_meta_analytics']
| where message == "agent.feedback" and signal == "win"
| project _time, audience, org, learned_for_agents, guidance_useful
| order by _time desc
| limit 40
```

### tools/list inventory (prove what Claude/GPT got)

```apl
['steward_meta_analytics']
| where message == "agent.tools_list"
| summarize n=count(), last=_time by client_name, audience, audience_source, mcp_endpoint, tool_count, tools_hash
| order by last desc
```

### Chat inventory regressions (wrong count / hash drift)

```apl
['steward_meta_analytics']
| where message == "agent.tools_list" and audience == "chat"
| summarize n=count(), last=max(_time) by tool_count, tools_hash, mcp_endpoint, client_name
| order by last desc
```

Expect one stable `tools_hash` for chat. New hashes after a deploy that intentionally changed `chat_surface` are fine; mixed hashes without a deploy mean URL/audience bugs.

### Misuse discovery (client called a tool not in registry)

```apl
['steward_meta_analytics']
| where message == "agent.tool" and signal == "misuse_discovery"
| summarize n=count() by tool_name, audience, client_name, mcp_endpoint, org
| order by n desc
```

Often: chat connector pointed at `/mcp/sse` (coding) then later a stale prompt, or coding tools advertised when chat was expected.

### Calls tagged by vendor client

```apl
['steward_meta_analytics']
| where message == "agent.tool"
| summarize n=count() by client_name, audience, tool_name
| order by n desc
| limit 40
```

## Fast improvement loop

1. **gap_empty / gap_info** → write memories/docs/skills for those `scope_path`s
2. **win** → `save_memory` / `skill_save` the `learned_for_agents` text
3. **pain** / **meta.error_cluster** → fix tools/prompts
4. **misuse_*** → tighten get_started / tool descriptions / `_next` hints; check `agent.tools_list` for wrong audience
5. **surprise_persist** → audit invent vs gap-fill
6. **meta.summary** success_rate trend → catch regressions after deploys
7. **agent.tools_list** after connect → prove inventory; deploy `SMOKE_API_KEY` smoke catches chat allowlist breaks

## Live poking (no Axiom wait)

- Local MCP: `acs` → `localhost`
- Prod MCP: `acs_prod` → `https://prod.stewardacs.xyz` (disable the other in opencode/Cursor when targeting one)
- After a Claude/GPT connect, query `agent.tools_list` for that `client_name` within a minute
- Deploy path: `/mcp/health` → optional DCR → optional `smoke-chat-tools.sh`
