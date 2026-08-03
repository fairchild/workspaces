---
name: subagent-delegation
description: >
  Repo-specific conventions for briefing implementation subagents and gating
  their PRs before ready-for-review. Use when fanning work out across parallel
  subagents/worktrees. Triggers: "delegate this", "spin up agents",
  "brief a subagent", "gate this PR".
---

# subagent-delegation: repo conventions for briefs and gates

Only what's specific to this repo — general delegation practice is assumed.
Source: the 2026-07-02 cycle (PRs #723–#732, six first-try gate passes).

## Before dispatching to a new execution agent

An agent that cannot run this repo's verification loop cannot ship here,
regardless of model quality — every merge gate is verification (`swift
build`/`swift test`, lint, evidence, smoke lanes). Proven 2026-07-08: a
pi-vs-codex race on the same brief produced a plausible ~1,000-line
implementation from pi that died unverifiable (its sandbox blocked `swift`),
while codex shipped a reviewed PR in under an hour. So on an agent's first
dispatch:

- Confirm its sandbox/harness can execute `swift build` (or `mise run
  web:check` for web work) before handing it a slice.
- Spot-check context absorption with a short quiz (issue tracker? evidence
  gate? PR label vocabulary?) — agents differ in how strongly they weight
  `AGENTS.md`; a wrong answer means the brief must carry that context
  explicitly.
- Fresh worktrees need `Frameworks/GhosttyKit.xcframework` rsynced from the
  main checkout before `swift build` works at all.

## The brief must include

- Bootstrap: `git fetch origin main && git checkout -B claude/<slug> origin/main`.
  Name the branch in the brief; base on fresh main, never the orchestrator's branch.
- Grounded file:line facts marked **re-verify, don't trust — if reality differs,
  stop and report instead of guessing**. (Caught a wrong import-graph claim in
  #725 before it became a wrong deletion.)
- Environment caveats pointer: `docs/development/remote-sessions.md`
  (evidence token, mise, Playwright browser).
- For test-adding work: a **mutation check** — re-break the covered bug, prove
  the new test fails, revert, report which mutation ran.
- Evidence rules: never fabricate; blocked evidence is an explicit PR state
  with the reason; a green CI run link is the remote hosted-evidence convention.
- Ship protocol: draft PR only (the gate flips it ready); `Closes #N` in the
  body; on `agent`+`task` issues do **not** touch claim labels —
  `sync-execution-state.py` owns that lane (`backlog/CLAUDE.md`).
- PR-body Mergeability fields need real prose — the `readiness` check
  (`scripts/pr-readiness.py`) fails on empty/default/`n/a` answers; when a
  field doesn't apply, write *why* it doesn't. Read that script before the
  session's first PR body — it is the body contract.
- Author the Evidence section with a placeholder slot for the hosted CI link
  so the gate edits the PR body exactly once, at ready-flip (every body
  update resends the full text).

## The gate, before a PR leaves draft

Calibrate depth to risk — default tiers until #733 lands: docs/test-only →
diff read + CI + a directed review pass suffice; behavior → add an independent
suite re-run (don't trust reported counts); security/UI → add the
adversarial/visual passes below.

- Always: read the full diff; cite the green CI run in the Evidence section;
  check `Closes #N`.
- Security-touching: adversarial pass — bypass paths, every failure path no
  worse than pre-change behavior, signer/verifier secret parity.
- UI-touching: view the screenshots yourself; run the Playwright `full`
  project yourself (`web-ci.yml` runs `fast` only); when hosted upload is
  blocked, deliver screenshots to the owner through the session.
- Merge mechanics: pre-check with `git merge-tree --write-tree` (the legacy
  three-arg form false-negatives real conflicts); after resolving, re-run the
  full suite on the merged tree, capturing output to a file before filtering.
- Record a gate note in the PR body (what re-ran, on which commit), then flip
  to ready.

## Sequencing

Serialize PRs touching `package.json`/lockfile; everything else parallelizes in
worktrees. `web/tests/LEDGER.md` conflicts are expected and additive — keep
both blocks. One watch owns merge-event follow-through (merge and CI-success
events don't push to sessions) — `scripts/pr-wait.sh <sha>` is that watch.
