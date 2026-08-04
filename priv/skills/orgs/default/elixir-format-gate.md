---
description: "Enforce mix format on an Elixir repo: clear unformatted backlog, gate CI lint, and add a versioned pre-commit hook."
name: "elixir-format-gate"
proposed_by: "nahar emet"
scope_paths: ["github/workflows", "guides/deployment-testing"]
status: "approved"
tags: ["elixir", "formatting", "ci", "git-hooks", "quality-gate"]
when_to_use: "When `mix format --check-formatted` fails on many files, or when adding/editing format enforcement in CI or git hooks."
audit_reasoning: "The skill is exceptionally well-structured and actionable. It provides a clear, step-by-step guide with exact commands, file paths, and YAML snippets. The prerequisites are explicit, verification steps are concrete, and common failures are addressed. The description is distinct and informative, and the audience (coding) is perfectly matched with the technical depth and tool references. It is not a duplicate of any existing skill."
audit_score: 10
audit_status: "ok"
audited_at: "2026-08-04T16:11:51.734140Z"
approved_at: "2026-08-04T16:11:51.739897Z"
approved_by: "llm"
reviewed_at: "2026-08-04T16:11:51.739897Z"
reviewed_by: "llm"
---

## When to use

`mix format --check-formatted` fails on pre-existing unformatted `.ex`/`.exs` files and you want to (a) clear the backlog and (b) stop it growing via CI and a local pre-commit hook.

## Prerequisites

- Elixir/mix on PATH (`mix format` must work).
- Repo has a `.formatter.exs`. Note: formatter `inputs` only cover `config`/`lib`/`test` `.ex`/`.exs` (+ `mix.exs`, `.formatter.exs`) — it cannot touch `.md`/`.sh`.
- Working on `dev` branch (project rule); lock `ci.yml` + the guide before editing if using ACS.

## Steps

1. Clear the backlog (whole repo):
   ```bash
   mix format
   mix format --check-formatted   # expect "FORMAT CLEAN"
   ```
2. Gate CI. In `.github/workflows/ci.yml`, `lint` job, add a step before compile (fastest failure):
   ```yaml
   - name: Check formatting
     run: mix format --check-formatted
   ```
3. Add a versioned pre-commit hook at `scripts/git-hooks/pre-commit` (`.git/hooks/` is not versioned):
   - Shebang `#!/usr/bin/env bash`, `set -euo pipefail`, `ROOT="$(cd "$(dirname "$0")/../.." && pwd)"`.
   - Collect staged files: `staged="$(git diff --cached --name-only --diff-filter=ACMR -- '*.ex' '*.exs')"`; exit 0 if empty.
   - If `mix` missing, warn and exit 0 (CI still enforces).
   - Run `mix format --check-formatted "${files[@]}"`; on failure print `mix format <files>` hint and exit 1.
   - Honor `SKIP_FORMAT_CHECK=1` escape hatch.
   - `chmod +x scripts/git-hooks/pre-commit`.
4. Enable repo-locally (do not modify the user's git config without asking — document instead):
   ```bash
   git config core.hooksPath scripts/git-hooks
   ```
5. Document: update `guides/deployment-testing.md` — the CI `lint` bullet (add `mix format --check-formatted`), the "Updating the infra itself" table (add a Format gate row), and a short "Pre-commit format hook" subsection.

## Verification

- `mix format --check-formatted` exits 0.
- `bash -n scripts/git-hooks/pre-commit` passes; YAML parses (`python3 -c "import yaml;yaml.safe_load(open('.github/workflows/ci.yml'))"`).
- Functional: `git add <one formatted file> && ./scripts/git-hooks/pre-commit` prints "HOOK PASSED"; then `git reset` to keep the index clean.
- If a repo-wide format was part of the change, also run `mix compile --warnings-as-errors` (formatting alone must not break compile).

## Common failures

- **`mix format` modified files a concurrent agent also touched** — check `git status`/reflog before and after; leave non-`.ex` changes alone (`mix format` cannot have made them).
- **Hook not running after install** — confirm `git config core.hooksPath` points at `scripts/git-hooks` and the file is executable.
- **Backlog reappears because someone committed unformatted** — format fixes are legitimate diffs; do not revert them. CI now blocks future cases.
