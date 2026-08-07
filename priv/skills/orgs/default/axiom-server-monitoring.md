---
description: "Apply and operate the Steward ACS Axiom server dashboard + downtime/jump monitors (upsert scripts, vm.metrics heartbeat, vm.jump events)."
name: "axiom-server-monitoring"
proposed_by: "nahar emet"
scope_paths: ["scripts", "otel", "lib/acs/observability", "guides/ops"]
status: "approved"
tags: ["axiom", "monitoring", "observability", "ops", "downtime"]
when_to_use: "When applying the Axiom server dashboard/monitors after deploy, troubleshooting downtime or metric jumps, or adding new monitor/panel queries."
audit_reasoning: "The skill is exceptionally well-structured and actionable. It provides clear, numbered steps with exact commands, prerequisites (including token scope details), verification instructions, and detailed failure recovery. The description is distinct and informative, and the content depth is high with specific file paths, script names, and APL query patterns. It is unique among the existing skills and perfectly suited for a 'coding' audience."
audit_score: 10
audit_status: "ok"
audited_at: "2026-08-07T07:53:13.692847Z"
approved_at: "2026-08-07T07:53:13.698901Z"
approved_by: "llm"
reviewed_at: "2026-08-07T07:53:13.698901Z"
reviewed_by: "llm"
---

# Axiom server monitoring (downtime + metric jumps)

How the Steward ACS server is monitored in Axiom and how to apply/update it.

## When to use
- After a prod deploy, to (re)apply the dashboard + monitors.
- To check whether a reported outage was real (heartbeat gap) vs a config-only issue.
- To add a new metric/monitor/panel.

## Signal sources
- `vm.metrics` events: emitted every 30s by `Acs.Observability.VmMetrics` (lib/acs/observability/vm_metrics.ex) into the Events dataset (default `steward_logs`) via the log ingest path. Fields include memory_*_bytes, process_count, atom_count, scheduler_utilization, cgroup_cpu_utilization, host_memory_*_bytes.
- `vm.jump` events: emitted when a metric jumps between consecutive samples past a threshold (delta scheduler_utilization >= 0.5, delta cgroup_cpu >= 0.8, pct memory_total >= 20, pct memory_processes >= 50, pct process_count >= 50). Configurable at runtime via Application env `:vm_jump_thresholds` or `start_link(jump_config:)`.
- OTel hostmetrics (cpu/mem/load/disk/net) via `otel_collector` compose profile (otel/collector-config.yaml) → Metrics dataset (default `steward-acs-metrics`).

## Prerequisites
- An Axiom API token with management scopes: datasets/dashboards/monitors read+write. The ingest-only token (AXIOM_LOGS in local .env, xaat-b... prefix) returns 403 on the management API — it CANNOT apply these.
- Axiom management API base is always https://api.axiom.co (ingest/query use the edge domain instead).

## Steps
1. Apply the dashboard (creates metrics dataset + upserts "Steward ACS — server"):
   AXIOM_TOKEN=xaat-... ./scripts/axiom-upsert-server-dashboard.sh
2. Apply the monitors (creates/updates "server down (no heartbeat)" + "metric jump"):
   AXIOM_TOKEN=xaat-... ./scripts/axiom-upsert-server-monitors.sh
3. Verify in Axiom UI → Dashboards → "Steward ACS — server": heartbeat panel (count of vm.metrics per 1m) should be non-zero, latest-heartbeat statistic should be within the last minute.
4. Attach notifiers: Axiom UI → Monitors → each "Steward ACS — …" → add Slack/email notifier (the upsert script creates monitors with empty notifierIDs).

## Monitoring reads (how to read an incident)
- Heartbeat panel gap + "server down" monitor firing = the app stopped emitting vm.metrics (crash, host unreachable, or OTel/ingest loss) → real downtime.
- No gap but Claude/connector issues = config drift (e.g. OAuth flag), NOT downtime. See prod-outage-triage skill.
- Jump panel + "metric jump" monitor firing = a sudden resource spike; correlate with deploy timestamps (GitHub Actions run times).

## Failure modes
- If dashboard upsert returns 403 on dataset create: dataset may already exist — script continues if GET succeeds; otherwise create the Metrics dataset in the UI first.
- If monitor upsert 401/403: token lacks monitors scope; create the monitors in the Axiom UI manually using the same APL queries.
- New panels/monitors can't be validated from a sandbox with only an ingest token — write queries following existing patterns (`where message == "..." | summarize ... by bin(_time, 1m)`) which are known-good.
- otel/ and scripts/axiom-*.sh are NOT in deploy.yml watched paths — dashboard/monitor changes do NOT auto-deploy; run the scripts manually after deploy.
