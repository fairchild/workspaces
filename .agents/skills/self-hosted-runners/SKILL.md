---
name: self-hosted-runners
description: >
  Reason about this repo's retired self-hosted GitHub Actions lanes. Use when a
  job is queued against a self-hosted label, or when deciding whether to
  re-provision the signing-host lane. No runner is registered and no workflow
  dispatches to one, so a queued or failing job is never a runner-health problem.
---

# Self-Hosted Runners

Use this skill when the problem is runner health, scheduling, or lane ownership rather than repo code.

**No workflow in this repo dispatches to a self-hosted runner, and none is
registered.** Release signing and notarization moved to hosted `macos-15` in
#1293, and `blue-workspaces` — the last runner, carrying `signing-host` — was
deregistered and removed from the host on 2026-08-13.

That makes runner health the wrong diagnosis for a stuck release. A queued or
failed release job is a workflow, CI, or credential problem; check
`scripts/release-preflight.sh`'s output before looking at any runner.

Behavioral UI smoke runs on
GitHub-hosted `macos-15` (`ui-smoke-advisory.yml`). Agent evidence — the
`gather` job in `_evidence.yml` — runs on hosted `macos-15` too; the
`lume-macos` VM lane that once carried it is retired. Perf benchmarks run on the
owner's laptop, opt-in per approved session
(`docs/decisions/perf-measurement-laptop-optin.md`) — the `tart-ui` lane that
once carried those is retired as well.

`.github/actionlint.yaml` lists the only labels a workflow may target, and that
list is now empty, so any reach for a self-hosted lane fails lint rather than
queueing against nothing.

Run `./scripts/runners.py` to see every runner on the current machine with its
local config, launchd state, and GitHub registration reconciled.

## Quick Start

Summarize GitHub runner inventory, queued jobs, and local runner directories:

```bash
./.agents/skills/self-hosted-runners/scripts/summarize_runner_state.py
```

Include one specific run when a queued or failed run is the immediate problem:

```bash
./.agents/skills/self-hosted-runners/scripts/summarize_runner_state.py \
  --run-id 24034959203
```

## Workflow

### 1. Inspect the current lane state

- Run `summarize_runner_state.py` first.
- Every lane is retired, so a job queued against any self-hosted label is a
  workflow bug rather than an outage — check `.github/actionlint.yaml`, which
  should have rejected it before merge.
- If a specific run is queued or failed, pass `--run-id`.
- Read [references/recovery-order.md](references/recovery-order.md) for the standard recovery order.

### 2. Recover the lane with the smallest safe change
5. If a host fallback runner goes online and then flips offline while the local process is still alive, treat that as a host-side communication problem rather than a repo problem.

For `signing-host`: nothing to recover — there is no runner to bring online.
Restoring releases to it is a re-provision, not a recovery step: register a host
per `docs/development/signing-runner-setup.md`, add the label back to
`.github/actionlint.yaml`, drop it from `RETIRED_RUNNER_LABELS` in
`scripts/audit-security-posture.py`, then change `runs-on` in `release.yml`.
Take it only if hosted signing or notarization is what failed, and say so in the
PR.

### 3. Use the lane-specific repo runbooks

Primary doc:

- `docs/development/signing-runner-setup.md`

`docs/development/lume-runner-setup.md` and `docs/development/tart-runner-setup.md`
are archival — both lanes they provision are retired. Read them only if a VM lane
is being stood up from scratch again.

Use the skill scripts to narrow the failure mode first, then jump into the lane-specific doc section you need.

### 4. Interpret the failure before retrying

Read [references/failure-signatures.md](references/failure-signatures.md) when the symptoms are ambiguous.

Important patterns:

- `registration has been deleted`: the runner must be re-registered
- `A session for this runner already exists`: a stale session or a still-running local process is blocking a new listener
- `online` then `offline` while `busy`: likely host-side communication loss, not a simple label problem

### 5. Prefer stable recovery paths

- Prefer a fresh host fallback runner name and directory over trying to salvage a strange local runner state.
- Prefer proving that a runner can stay online and accept one job before relying on it for release work.

## Standalone Scripts

### `summarize_runner_state.py`

Use for host-plus-GitHub runner triage.

- lists GitHub runner inventory
- lists queued runs
- optionally summarizes one specific run's jobs
- inspects known local runner directories and recent diagnostic signatures

### `runners.py`

Use for a full picture of every runner on the current machine: `./scripts/runners.py`.
Reconciles local `.runner` config, launchd state, and GitHub registration, and
reports a runner as dead when launchd has given up on it permanently.

## Guardrails

- Do not assume queued means "no runner exists". A runner can be online briefly, accept a session, then lose communication.
- Do not stand a VM lane back up to fix a queued job. Both VM lanes are retired; a job queued against one is a workflow bug, not a runner outage.
- Do not keep reusing a host fallback runner name that has session-conflict behavior. Register a fresh runner name if needed.
- When a runner process is alive locally but GitHub shows it offline, classify that as a host-side problem first.
