# Blue/green helpers for multi-tenant ACS cutover. Sourced by deploy.sh (remote).
# shellcheck shell=bash

acs_other_slot() {
  case "${1:-}" in
    blue) echo green ;;
    green) echo blue ;;
    *)
      echo "ERROR: ACS slot must be blue|green (got: ${1:-empty})" >&2
      return 1
      ;;
  esac
}

acs_container() {
  echo "steward_acs_${1}"
}

acs_service() {
  echo "steward_acs_${1}"
}

# Write Caddy import snippet that points at the given slot.
# Usage: acs_write_upstream /path/to/acs_upstream.caddyfile blue
acs_write_upstream() {
  local path="$1" slot="$2"
  cat >"$path" <<EOF
# Active ACS upstream for Caddy (blue/green). Deploy rewrites this file and
# runs \`caddy reload\` — do not edit by hand on the host during a cutover.
reverse_proxy steward_acs_${slot}:4001 {
	flush_interval -1
}
EOF
}

# Hash of Caddy static config (file + TLS material). Upstream snippet excluded —
# that changes every blue/green flip and should only trigger reload, not recreate.
acs_caddy_bundle_hash() {
  local root="${1:-.}"
  (
    cd "$root" || exit 1
    # shellcheck disable=SC2046
    sha256sum Caddyfile.multitenant \
      $(find certs -type f \( -name '*.pem' -o -name '*.key' -o -name '*.crt' \) 2>/dev/null | sort) \
      2>/dev/null | sha256sum | awk '{print $1}'
  )
}
