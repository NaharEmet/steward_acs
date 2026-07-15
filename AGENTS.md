Check if `@AGENTS_STEWARD.md` exists. If yes, follow the instructions there. If not, ignore this line.

**Do not do work without a task.** Create or claim one in ACS immediately when asked to do anything.

**Do not finish without releasing + feedback.** Always call `acs_release_work` and `acs_submit_task_feedback` before declaring done.

## Guides

Project-specific workflows live in `guides/`. Check them before starting work:

- [`guides/secrets.md`](guides/secrets.md) — managing secrets with `pass`
- [`guides/steward-installer.md`](guides/steward-installer.md) — installing ACS for new users
- [`guides/deployment.md`](guides/deployment.md) — local + multi-tenant prod (+ Postgres override)
- [`priv/skills/steward-installer.md`](priv/skills/steward-installer.md) — installer walkthrough (`bin/setup.sh`)
