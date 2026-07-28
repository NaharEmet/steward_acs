#!/usr/bin/env bash
# Create/update the Steward ACS LLM usage dashboard (tokens, latency, errors).
#
# Agents: prefer the user-axiom MCP `createDashboard` / `updateDashboard` tools
# (see .cursor/rules/axiom-mcp.mdc). This script is a human fallback when you have
# a management AXIOM_TOKEN with dashboards:create (ingest AXIOM_LOGS alone is not enough).
#
# Usage:
#   AXIOM_TOKEN=xaat-… ./scripts/axiom-upsert-llm-dashboard.sh
#   AXIOM_LOGS=xaat-… ./scripts/axiom-upsert-llm-dashboard.sh   # only if token can create dashboards
#
# Env:
#   AXIOM_TOKEN / AXIOM_LOGS     API token (required)
#   AXIOM_API                   management API base (default https://api.axiom.co)
#   AXIOM_DATASET               Events dataset (default steward_logs)
#   AXIOM_DASHBOARD_UID         stable uid (default steward-acs-llm)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOKEN="${AXIOM_TOKEN:-${AXIOM_LOGS:-}}"
API="${AXIOM_API:-https://api.axiom.co}"
LOGS_DS="${AXIOM_DATASET:-steward_logs}"
DASH_UID="${AXIOM_DASHBOARD_UID:-steward-acs-llm}"
TEMPLATE="${ROOT}/otel/axiom-llm-dashboard.json"

if [[ -z "$TOKEN" ]]; then
  echo "ERROR: set AXIOM_TOKEN (or AXIOM_LOGS) with dashboards permissions" >&2
  exit 1
fi
if [[ ! -f "$TEMPLATE" ]]; then
  echo "ERROR: missing $TEMPLATE" >&2
  exit 1
fi

auth_hdr=(-H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json")

dashboard=$(
  jq \
    --arg d "$LOGS_DS" \
    'walk(if type == "string" then gsub("__LOGS_DATASET__"; $d) else . end)' \
    "$TEMPLATE"
)

echo "[axiom] upserting dashboard uid=${DASH_UID} dataset=${LOGS_DS}"
payload=$(jq -n --argjson d "$dashboard" --arg uid "$DASH_UID" \
  '{dashboard:$d, uid:$uid, overwrite:true, message:"Steward ACS LLM usage dashboard"}')

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
echo "[axiom] open Dashboards — \"Steward ACS — LLM usage\""
echo "[axiom] APL starter:"
echo "  ['${LOGS_DS}'] | where action == \"llm_call\" | summarize count() by status, call_type, error_type"
