#!/usr/bin/env bash
# Create/update Steward ACS server monitors in Axiom:
#   1. "Steward ACS — server down (no heartbeat)"  fires when vm.metrics
#      heartbeat events stop arriving (server down / app crash / network cut).
#   2. "Steward ACS — metric jump"                  fires when the app detects
#      a sudden jump (vm.jump event) in memory / CPU / process count.
#
# Both are Axiom Threshold monitors on the Events dataset (steward_logs by
# default). "Alert on no data" on the downtime monitor also covers a complete
# loss of ingest (e.g. host unreachable).
#
# Usage (token needs monitors read/write on the Events dataset):
#   AXIOM_TOKEN=xaat-… ./scripts/axiom-upsert-server-monitors.sh
#
# Env:
#   AXIOM_TOKEN / AXIOM_LOGS   API token (required)
#   AXIOM_API                  management API base (default https://api.axiom.co)
#   AXIOM_DATASET              Events dataset (default steward_logs)
set -euo pipefail

TOKEN="${AXIOM_TOKEN:-${AXIOM_LOGS:-}}"
API="${AXIOM_API:-https://api.axiom.co}"
EVENTS_DS="${AXIOM_DATASET:-steward_logs}"

if [[ -z "$TOKEN" ]]; then
  echo "ERROR: set AXIOM_TOKEN (or AXIOM_LOGS) with monitors permissions" >&2
  exit 1
fi

auth_hdr=(-H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json")

# AXIOM's APL query must reference the Events dataset literally; no jq token
# substitution needed here since only one dataset is used.

DOWN_NAME="Steward ACS — server down (no heartbeat)"
DOWN_APL="['${EVENTS_DS}']
| where ['message'] == \"vm.metrics\"
| summarize c=count()"

JUMP_NAME="Steward ACS — metric jump"
JUMP_APL="['${EVENTS_DS}']
| where ['message'] == \"vm.jump\"
| summarize c=count()"

# GET existing monitors once; used for both upserts.
monitors_json=$(curl -sS -f "${auth_hdr[@]}" "${API}/v2/monitors") || {
  echo "ERROR: GET ${API}/v2/monitors failed (token needs monitors read)" >&2
  exit 1
}

upsert_monitor() {
  local name="$1" apl="$2" operator="$3" threshold="$4" alert_no_data="$5"

  body=$(jq -n \
    --arg name "$name" \
    --arg description "Steward ACS server monitor (see scripts/axiom-upsert-server-monitors.sh)" \
    --arg apl "$apl" \
    --arg operator "$operator" \
    --argjson threshold "$threshold" \
    --argjson alertOnNoData "$alert_no_data" \
    --argjson intervalMinutes 5 \
    --argjson rangeMinutes 10 \
    '{name:$name, type:"Threshold", description:$description, aplQuery:$apl,
      operator:$operator, threshold:$threshold, alertOnNoData:$alertOnNoData,
      notifyByGroup:false, notifierIDs:[], intervalMinutes:$intervalMinutes,
      rangeMinutes:$rangeMinutes, disabled:false}')

  id=$(echo "$monitors_json" | jq -r --arg name "$name" \
    '.[] | select(.name == $name) | .id' | head -n1)

  if [[ -n "$id" ]]; then
    echo "[axiom] updating monitor '${name}' (id=${id})"
    resp=$(curl -sS -w "\n%{http_code}" "${auth_hdr[@]}" \
      -X PUT "${API}/v2/monitors/${id}" -d "$body")
  else
    echo "[axiom] creating monitor '${name}'"
    resp=$(curl -sS -w "\n%{http_code}" "${auth_hdr[@]}" \
      -X POST "${API}/v2/monitors" -d "$body")
  fi

  resp_body=$(echo "$resp" | sed '$d')
  code=$(echo "$resp" | tail -n1)

  if [[ "$code" != "200" && "$code" != "201" ]]; then
    echo "ERROR: monitor upsert HTTP ${code}" >&2
    echo "$resp_body" >&2
    exit 1
  fi

  echo "$resp_body" | jq -r '"[axiom] monitor " + .name + " id=" + .id'
}

upsert_monitor "$DOWN_NAME" "$DOWN_APL" "Below" 1 true
upsert_monitor "$JUMP_NAME" "$JUMP_APL" "Above" 0 false

echo "[axiom] done. Open the Axiom UI → Monitors → \"Steward ACS — …\" to attach notifiers."
