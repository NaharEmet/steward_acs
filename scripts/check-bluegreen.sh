#!/usr/bin/env bash
# Self-check for blue/green helpers. Fails if slot math or upstream write breaks.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/acs_bluegreen.sh
source "$ROOT/scripts/lib/acs_bluegreen.sh"

[[ "$(acs_other_slot blue)" == green ]]
[[ "$(acs_other_slot green)" == blue ]]
[[ "$(acs_container blue)" == steward_acs_blue ]]
[[ "$(acs_service green)" == steward_acs_green ]]

tmp="$(mktemp)"
acs_write_upstream "$tmp" green
grep -q 'steward_acs_green:4001' "$tmp"
grep -q 'flush_interval -1' "$tmp"
rm -f "$tmp"

if ! acs_other_slot red 2>/dev/null; then
  :
else
  echo "ERROR: expected acs_other_slot red to fail" >&2
  exit 1
fi

echo "check-bluegreen: ok"
