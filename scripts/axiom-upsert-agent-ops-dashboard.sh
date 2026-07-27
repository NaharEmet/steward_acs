#!/usr/bin/env bash
# Create/update the Steward ACS agent-usage dashboard and ensure the
# steward_meta_analytics Events dataset exists.
#
# Usage:
#   AXIOM_TOKEN=xaat-… ./scripts/axiom-upsert-agent-ops-dashboard.sh
#   AXIOM_LOGS=xaat-… ./scripts/axiom-upsert-agent-ops-dashboard.sh
#
# Env:
#   AXIOM_TOKEN / AXIOM_LOGS     API token (required)
#   AXIOM_API                   management API base (default https://api.axiom.co)
#   AXIOM_AGENT_OPS_DATASET     Events dataset (default steward_meta_analytics)
#   AXIOM_DASHBOARD_UID         stable uid (default steward-acs-agent-usage)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOKEN="${AXIOM_TOKEN:-${AXIOM_LOGS:-}}"
API="${AXIOM_API:-https://api.axiom.co}"
OPS_DS="${AXIOM_AGENT_OPS_DATASET:-steward_meta_analytics}"
DASH_UID="${AXIOM_DASHBOARD_UID:-steward-acs-agent-usage}"
TEMPLATE="${ROOT}/otel/axiom-agent-ops-dashboard.json"

if [[ -z "$TOKEN" ]]; then
  echo "ERROR: set AXIOM_TOKEN (or AXIOM_LOGS) with datasets+dashboards permissions" >&2
  exit 1
fi
if [[ ! -f "$TEMPLATE" ]]; then
  echo "ERROR: missing $TEMPLATE" >&2
  exit 1
fi

auth_hdr=(-H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json")

echo "[axiom] ensuring events dataset '${OPS_DS}'"
if [[ "${AXIOM_SKIP_DATASET_CREATE:-}" == "1" ]]; then
  echo "[axiom] AXIOM_SKIP_DATASET_CREATE=1 — skipping dataset create"
else
status=$(curl -sS -o /tmp/axiom-agent-ops-ds.json -w "%{http_code}" \
  "${auth_hdr[@]}" \
  -X POST "${API}/v2/datasets" \
  -d "$(jq -n --arg n "$OPS_DS" '{name:$n, description:"Steward agent.tool / agent.feedback usage events for Claude and coding agents"}')") || true

case "$status" in
  200) echo "[axiom] created dataset ${OPS_DS}" ;;
  403)
    echo "[axiom] token lacks datasets|create (HTTP 403)." >&2
    if curl -sS -f "${auth_hdr[@]}" "${API}/v2/datasets/${OPS_DS}" >/dev/null 2>&1; then
      echo "[axiom] dataset ${OPS_DS} already reachable — continuing"
    else
      echo "  Create Events dataset '${OPS_DS}' in the Axiom UI (or set AXIOM_SKIP_DATASET_CREATE=1 if it exists), then re-run." >&2
      exit 1
    fi
    ;;
  400|409)
    if curl -sS -f "${auth_hdr[@]}" "${API}/v2/datasets/${OPS_DS}" >/dev/null 2>&1; then
      echo "[axiom] dataset ${OPS_DS} already exists"
    else
      echo "[axiom] dataset create returned HTTP ${status}; body:" >&2
      cat /tmp/axiom-agent-ops-ds.json >&2 || true
      exit 1
    fi
    ;;
  *)
    echo "[axiom] dataset create HTTP ${status}; body:" >&2
    cat /tmp/axiom-agent-ops-ds.json >&2 || true
    if curl -sS -f "${auth_hdr[@]}" "${API}/v2/datasets/${OPS_DS}" >/dev/null 2>&1; then
      echo "[axiom] dataset ${OPS_DS} reachable — continuing"
    else
      exit 1
    fi
    ;;
esac
fi

dashboard=$(
  jq \
    --arg d "$OPS_DS" \
    'walk(if type == "string" then gsub("__AGENT_OPS_DATASET__"; $d) else . end)' \
    "$TEMPLATE"
)

echo "[axiom] upserting dashboard uid=${DASH_UID}"
payload=$(jq -n --argjson d "$dashboard" --arg uid "$DASH_UID" \
  '{dashboard:$d, uid:$uid, overwrite:true, message:"Steward ACS agent usage dashboard"}')

resp=$(curl -sS -w "\n%{http_code}" \
  "${auth_hdr[@]}" \
  -X POST "${API}/v2/dashboards" \
  -d "$payload")
body=$(echo "$resp" | sed '$d')
code=$(echo "$resp" | tail -n1)

if [[ "$code" != "200" && "$code" != "201" ]]; then
  echo "ERROR: dashboard upsert HTTP ${code}" >&2
  echo "$body" >&2
  exit 1
fi

echo "$body" | jq -r '"[axiom] dashboard " + (.status // "ok") + " id=" + (.dashboard.id // .id // "?") + " uid=" + (.dashboard.uid // .uid // "?")'
echo "[axiom] open Dashboards — \"Steward ACS — agent usage\""
echo "[axiom] agent APL starter:"
echo "  ['${OPS_DS}'] | where message == \"agent.tool\" | summarize count() by tool_family, audience, empty_result"
