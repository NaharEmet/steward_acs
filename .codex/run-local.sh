#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

set -a
source .env
set +a

export CODEX_HOME="$project_root/.codex"
exec codex "$@"
