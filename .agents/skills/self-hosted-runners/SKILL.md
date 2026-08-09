---
name: self-hosted-runners
description: >
  Inspect, recover, and operate this repo's self-hosted GitHub Actions
  runners across the signing-host and lume-macos lanes.
  Use when jobs are queued, runners show offline or busy unexpectedly,
  release jobs do not start, a Lume runner VM needs recovery, or when
  you need a host fallback runner on the current machine.
---

# Self-Hosted Runners

Use this skill when the problem is runner health, scheduling, or lane ownership rather than repo code.

This repo has two self-hosted lanes:

- `signing-host` for release signing and notarization
- `lume-macos` for macOS CI and agent execution

Two things that used to be self-hosted no longer are, so do not go looking for a
lane when one of these is the real question. Behavioral UI smoke runs on
GitHub-hosted `macos-15` (`ui-smoke-advisory.yml`). Perf benchmarks run on the
owner's laptop, opt-in per approved session
(`docs/decisions/perf-measurement-laptop-optin.md`) — the `tart-ui` lane that
once carried both is retired.

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

Probe the `lume-macos` guest directly over SSH:

```bash
./.agents/skills/self-hosted-runners/scripts/probe_lume_runner_guest.py
```

If `lume get` does not report the guest IP but direct SSH is known to work:

```bash
./.agents/skills/self-hosted-runners/scripts/probe_lume_runner_guest.py \
  --ip 192.168.8.233
```

If you already know the lane is `lume-macos`, use the Lume guest probe before guessing.

## Workflow

### 1. Inspect the current lane state

- Run `summarize_runner_state.py` first.
- Identify which lane is actually blocked: `signing-host` or `lume-macos`.
- If a specific run is queued or failed, pass `--run-id`.
- Read [references/recovery-order.md](references/recovery-order.md) for the standard recovery order.

### 2. Recover the lane with the smallest safe change

For `lume-macos`:

1. Confirm the VM exists and is running.
2. Probe the guest over SSH with `probe_lume_runner_guest.py`.
3. If the guest runner registration is stale, re-register it.
4. If the guest is missing Xcode or is otherwise not build-ready, stop using it for CI and switch to a host fallback runner.
5. If a host fallback runner goes online and then flips offline while the local process is still alive, treat that as a host-side communication problem rather than a repo problem.

For `signing-host`:

1. Confirm at least one runner is online with the `signing-host` label.
2. Start the configured runner on the intended machine.
3. Verify the release run lands on that lane before debugging signing details.

### 3. Use the lane-specific repo runbooks

Primary docs:

- `docs/development/lume-runner-setup.md`
- `docs/development/signing-runner-setup.md`

`docs/development/tart-runner-setup.md` is archival — the lane it provisions is
retired. Read it only if a Tart lane is being stood up from scratch again.

Use the skill scripts to narrow the failure mode first, then jump into the lane-specific doc section you need.

### 4. Interpret the failure before retrying

Read [references/failure-signatures.md](references/failure-signatures.md) when the symptoms are ambiguous.

Important patterns:

- `registration has been deleted`: the runner must be re-registered
- `A session for this runner already exists`: a stale session or a still-running local process is blocking a new listener
- `online` then `offline` while `busy`: likely host-side communication loss, not a simple label problem
- `xcode-select` points to Command Line Tools and no `Xcode.app` exists: the Lume guest is not build-ready for macOS CI

### 5. Prefer stable recovery paths

- Prefer direct SSH into the Lume guest once passwordless SSH works.
- Prefer a fresh host fallback runner name and directory over trying to salvage a strange local runner state.
- Prefer proving that a runner can stay online and accept one job before relying on it for release work.

## Standalone Scripts

### `summarize_runner_state.py`

Use for host-plus-GitHub runner triage.

- lists GitHub runner inventory
- lists queued runs
- optionally summarizes one specific run's jobs
- inspects known local runner directories and recent diagnostic signatures

### `probe_lume_runner_guest.py`

Use for `lume-macos` guest recovery.

- checks VM state from `lume get`
- connects over direct SSH when an IP is available
- reports guest OS, Xcode readiness, runner service state, and recent guest runner log signatures

## Guardrails

- Do not assume queued means "no runner exists". A runner can be online briefly, accept a session, then lose communication.
- Do not keep rerunning jobs on a Lume guest that is missing Xcode.
- Do not keep reusing a host fallback runner name that has session-conflict behavior. Register a fresh runner name if needed.
- When a runner process is alive locally but GitHub shows it offline, classify that as a host-side problem first.
