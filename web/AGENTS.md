# web/ - Maintenance-Mode Dashboard

`CLAUDE.md` here is a symlink to this file — read one, not both.

**Maintenance mode since #754 (2026-07-08):** no new development, old chat/terminal demoted; still serves GitHub webhook ingestion. Its managed PR reviewer was retired separately (`docs/decisions/managed-reviewer-retirement.md`). New web work happens in `web-next/`, not here. Stack + local dev: `web/README.md`.

## Local Dev

Always use the `mise run web:*` tasks, never raw pnpm chains — full catalog, caveats (including the `NODE_ENV=production` requirement for `fast/unauth-*` specs), and anti-patterns in `web/docs/local-dev.md`. Tasks live in `web/.mise.toml` (not chain-loaded from root): run after `cd web/` or with `mise -C web run ...`. Most used: `web:check` (typecheck + lint + unit tests), `web:dev` (seeded dev server + auth bypass), `web:e2e`, `web:evidence -- --pr <N> --name <slug>`, `web:deps -- <pkg>`.

## QA

`qa-web-agent` (`.claude/agents/qa-web-agent.md`) is the project-local subagent for `web/` testing — Explore (black-box), Author (spec-first, human-gated), Heal (selector drift vs regression). Invoke via `/qa` (`.claude/commands/qa.md`): `explore [area]`, `author <slug>`, `heal [test-path]`, `run`, `ledger`. Coverage is measured against `web/tests/LEDGER.md` (behavior → test → last-verified date), not line-coverage %; new behaviors worth automating land in the ledger with a matching spec and test.
