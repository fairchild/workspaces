---
name: self-hosted-runners
description: >
  Inspect, recover, and operate this repo's self-hosted GitHub Actions
  runners on the signing-host lane.
  Use when jobs are queued, runners show offline or busy unexpectedly,
  release jobs do not start, or when you need a host fallback runner on
  the current machine.
---

# Self-Hosted Runners

Use this skill when the problem is runner health, scheduling, or lane ownership rather than repo code.

This repo has one self-hosted lane:

- `signing-host` for release signing and notarization

Everything else that used to be self-hosted no longer is, so do not go looking
for a lane when one of these is the real question. Behavioral UI smoke runs on
GitHub-hosted `macos-15` (`ui-smoke-advisory.yml`). Agent evidence — the
`gather` job in `_evidence.yml` — runs on hosted `macos-15` too; the
`lume-macos` VM lane that once carried it is retired. Perf benchmarks run on the
owner's laptop, opt-in per approved session
(`docs/decisions/perf-measurement-laptop-optin.md`) — the `tart-ui` lane that
once carried those is retired as well.

`.github/actionlint.yaml` lists the only labels a workflow may target, so a
reach for a retired lane fails lint rather than queueing against nothing.

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
- `signing-host` is the only lane, so a blocked job is either that lane or not a
  lane problem at all. A job queued against any other label is a workflow bug —
  check `.github/actionlint.yaml`.
- If a specific run is queued or failed, pass `--run-id`.
- Read [references/recovery-order.md](references/recovery-order.md) for the standard recovery order.

### 2. Recover the lane with the smallest safe change
5. If a host fallback runner goes online and then flips offline while the local process is still alive, treat that as a host-side communication problem rather than a repo problem.

For `signing-host`:

1. Confirm at least one runner is online with the `signing-host` label.
2. Start the configured runner on the intended machine.
3. Verify the release run lands on that lane before debugging signing details.

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
