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
| `agent.feedback` | Task feedback close |
| `meta.summary` | Hourly rollup (totals, success_rate) |
| `meta.tool` | Per-tool reliability + latency |
| `meta.error_cluster` | Grouped failures |
| `meta.agent` | Per-agent behavior |

Dashboard: `./scripts/axiom-upsert-agent-ops-dashboard.sh` → **Steward ACS — agent usage**.

Prod: `META_HARNESS_ENABLED=true` buffers `acs_tool_operations` and ships hourly `meta.*` into the same dataset.

## Learning signals (`signal` on agent.tool / agent.feedback)

| `signal` | Quadrant | Meaning | Action |
|----------|----------|---------|--------|
| `works` | Planned + good | Retrieve hits or clean writes | Keep / amplify patterns |
| `win` | Unplanned + good | Feedback `learned_for_agents` filled | Promote into memories/skills |
| `surprise_persist` | Unplanned + good? | Write after empty retrieve | Audit: real gap-fill vs invent |
| `gap_empty` | Planned missing | Retrieve returned 0 | Seed knowledge / fix scopes |
| `gap_info` | Planned missing | Feedback `info_needed` | Same — backlog for content |
| `pain` | Broken | Feedback issues/improvements | Fix tools/prompts |
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

### Meta-Harness hourly health

```apl
['steward_meta_analytics']
| where message == "meta.summary"
| project _time, total_ops, success_rate, failure_count, discovery_count, active_agents
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

## Fast improvement loop

1. **gap_empty / gap_info** → write memories/docs/skills for those `scope_path`s
2. **win** → `save_memory` / `skill_save` the `learned_for_agents` text
3. **pain** / **meta.error_cluster** → fix tools/prompts
4. **misuse_*** → tighten get_started / tool descriptions / `_next` hints
5. **surprise_persist** → audit invent vs gap-fill
6. **meta.summary** success_rate trend → catch regressions after deploys
