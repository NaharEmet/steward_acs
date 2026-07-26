#!/usr/bin/env bash
# Create/update the Steward ACS server monitoring dashboard in Axiom, and ensure
# the Metrics dataset exists for the otel_collector hostmetrics pipeline.
#
# Usage (token needs datasets create + dashboards write + ingest on both datasets):
#   AXIOM_TOKEN=xaat-… ./scripts/axiom-upsert-server-dashboard.sh
#   # or reuse the ingest token if it has management scopes:
#   AXIOM_LOGS=xaat-… ./scripts/axiom-upsert-server-dashboard.sh
#
# Env:
#   AXIOM_TOKEN / AXIOM_LOGS     API token (required)
#   AXIOM_API                   management API base (default https://api.axiom.co)
#   AXIOM_METRICS_DATASET       Metrics dataset (default steward-acs-metrics)
#   AXIOM_DATASET               Events dataset for vm.metrics panels (default steward_logs)
#   AXIOM_DASHBOARD_UID         stable uid (default steward-acs-server)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOKEN="${AXIOM_TOKEN:-${AXIOM_LOGS:-}}"
API="${AXIOM_API:-https://api.axiom.co}"
METRICS_DS="${AXIOM_METRICS_DATASET:-steward-acs-metrics}"
EVENTS_DS="${AXIOM_DATASET:-steward_logs}"
DASH_UID="${AXIOM_DASHBOARD_UID:-steward-acs-server}"
TEMPLATE="${ROOT}/otel/axiom-server-dashboard.json"

if [[ -z "$TOKEN" ]]; then
  echo "ERROR: set AXIOM_TOKEN (or AXIOM_LOGS) with datasets+dashboards permissions" >&2
  exit 1
fi
if [[ ! -f "$TEMPLATE" ]]; then
  echo "ERROR: missing $TEMPLATE" >&2
  exit 1
fi

auth_hdr=(-H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json")

echo "[axiom] ensuring metrics dataset '${METRICS_DS}' (otel:metrics:v1)"
status=$(curl -sS -o /tmp/axiom-ds.json -w "%{http_code}" \
  "${auth_hdr[@]}" \
  -X POST "${API}/v2/datasets" \
  -d "$(jq -n --arg n "$METRICS_DS" '{name:$n, description:"Host metrics from steward otel_collector", kind:"otel:metrics:v1"}')") || true

case "$status" in
  200) echo "[axiom] created dataset ${METRICS_DS}" ;;
  403)
    echo "[axiom] token lacks datasets|create (HTTP 403)." >&2
    echo "  Create Metrics dataset '${METRICS_DS}' in the Axiom UI (kind: Metrics)," >&2
    echo "  grant this token ingest on it, then re-run with a token that can write dashboards." >&2
    if curl -sS -f "${auth_hdr[@]}" "${API}/v2/datasets/${METRICS_DS}" >/dev/null 2>&1; then
      echo "[axiom] dataset ${METRICS_DS} already reachable — continuing to dashboard"
    else
      exit 1
    fi
    ;;
  400|409)
    # already exists / validation — confirm by GET
    if curl -sS -f "${auth_hdr[@]}" "${API}/v2/datasets/${METRICS_DS}" >/dev/null 2>&1; then
      echo "[axiom] dataset ${METRICS_DS} already exists"
    else
      echo "[axiom] dataset create returned HTTP ${status}; body:" >&2
      cat /tmp/axiom-ds.json >&2 || true
      exit 1
    fi
    ;;
  *)
    echo "[axiom] dataset create HTTP ${status}; body:" >&2
    cat /tmp/axiom-ds.json >&2 || true
    # If GET works, continue (token may lack create but dataset exists)
    if curl -sS -f "${auth_hdr[@]}" "${API}/v2/datasets/${METRICS_DS}" >/dev/null 2>&1; then
      echo "[axiom] dataset ${METRICS_DS} reachable — continuing"
    else
      exit 1
    fi
    ;;
esac

dashboard=$(
  jq \
    --arg m "$METRICS_DS" \
    --arg e "$EVENTS_DS" \
    '
      walk(
        if type == "string" then
          gsub("__METRICS_DATASET__"; $m) | gsub("__EVENTS_DATASET__"; $e)
        else . end
      )
    ' "$TEMPLATE"
)

echo "[axiom] upserting dashboard uid=${DASH_UID}"
payload=$(jq -n --argjson d "$dashboard" --arg uid "$DASH_UID" \
  '{dashboard:$d, uid:$uid, overwrite:true, message:"Steward ACS server monitoring dashboard"}')

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
echo "[axiom] open Dashboards in the Axiom UI — look for \"Steward ACS — server\""
