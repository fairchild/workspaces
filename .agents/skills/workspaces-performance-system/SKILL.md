---
name: workspaces-performance-system
description: >
  Run and maintain the canonical Workspaces performance contract across debug,
  installed, release, and CI environments. Use when collecting comparable
  before/after metrics, asserting scenario budgets, verifying installed-build
  parity, refreshing baselines, or classifying self-hosted perf lane failures
  as infrastructure versus product regressions. Prefer this skill over
  workspaces-optimization when the task is to operate the standardized
  performance system rather than investigate an unknown slowdown.
---

# Workspaces Performance System

Use this skill when the task is to run the performance system correctly and produce comparable evidence.

Use `workspaces-optimization` instead when the task is root-cause investigation on a slow machine or an unknown latency path.

## Quick Start

Run one canonical debug scenario and assert budgets:

```bash
./scripts/perf-runner.sh --scenario debug_no_activate --assert-budget
```

Compare before and after summaries:

```bash
./scripts/perf-compare.py before-summary.json after-summary.json
```

Verify release-bundle performance signoff on the packaged app:

```bash
./scripts/verify-installed-perf.sh build/WorkSpaces.app
```

## Core Workflow

### 1. Start from the contract

Read these first:

- `config/performance/contract.json`
- `docs/performance/metrics-reference.md`
- `docs/performance-testing.md`

The contract is the source of truth for:

- scenario ids
- metric coverage
- budget formulas
- PR versus scheduled-main gate policy

Do not invent new scenario names or hand-tuned thresholds in ad hoc scripts.

### 2. Pick the smallest canonical scenario

Use these scenario ids exactly:

- `debug_no_activate`
- `debug_activate`
- `installed_clean_shell`
- `installed_login_shell`
- `installed_input_short_capture`

Guidance:

- Use `debug_no_activate` for low-variance local branch comparisons and trend history, not release signoff.
- Use `debug_activate` for interactive local validation.
- Use `installed_clean_shell` to isolate app and terminal surface cost; this is the packaged-app release signoff scenario.
- Use `installed_login_shell` to include shell-init overhead.
- Use `installed_input_short_capture` only for short interactive focused typing captures.

### 3. Run through the wrapper first

Prefer the shared wrapper over calling collectors manually:

```bash
./scripts/perf-runner.sh --scenario installed_clean_shell --assert-budget
```

The wrapper exists to keep artifact shape consistent across debug and installed runs.

Use the older standalone scripts only when you need a narrower benchmark:

- `./scripts/perf-baseline.sh`
- `./scripts/new-workspace-perf.sh`
- `./scripts/launch-installed-diagnostics.sh`
- `./.agents/skills/workspaces-optimization/scripts/summarize_perf_log.py`
- `./.agents/skills/workspaces-optimization/scripts/summarize_diagnostic_report.py`

### 4. Compare canonical summaries, not raw impressions

For every optimization or regression check:

1. capture `before`
2. capture `after`
3. compare with `./scripts/perf-compare.py`
4. report metric deltas and budget status

Prefer median as the gate signal. Treat max and p95 as diagnostic signals.

### 5. Treat installed-build parity as mandatory

Before release or packaged-app signoff:

1. build the packaged app
2. run `./scripts/verify-release-bundle.sh`
3. run `./scripts/verify-installed-perf.sh`

Installed validation must confirm:

- bundled `ghostty` resources exist
- bundled `terminfo` exists
- installed clean-shell capture emits `terminal_first_output`
- installed clean-shell capture emits `first_prompt_ready`
- logs do not contain missing-resource warnings

If the verifier fails because the machine is headless or lacks a real display session, classify that as an environment limitation, not a product perf result. Release automation may use `./scripts/verify-installed-perf.sh --allow-skip-noninteractive` for that one case only.

Debug scenario failures are useful branch-trend evidence. They do not block a
release by themselves when the packaged app verifier passes and the debug
environment difference is explicitly classified.

### 6. Measurement is laptop-local and opt-in; report absence as absence

No workflow measures performance. Benchmarks run on the owner's laptop, one
approved session at a time — `docs/decisions/perf-measurement-laptop-optin.md`
is the protocol, including the per-sample kill gate, the quiet-machine load
precondition, and the `WORKSPACES_SYNTHETIC_ROOT` preferences isolation.

Rules:

- Read staleness from `docs/performance/dashboard.md`'s `Last updated`
  timestamp. If it is old, say "the last recorded measurement is from `<date>`"
  — never "perf is green" and never "perf is failing".
- A scenario nobody ran produced no result. Report it as not measured, distinct
  from measured-and-passed. This is the lesson the deleted perf cron encoded
  (#1238): a skipped measurement that reads as a pass hid a dead lane for weeks.
- Budgets are `Mac16,13`-derived. A number from other hardware is not comparable
  to them; the four channel scenarios can run anywhere but their budgets still
  cannot be asserted off-host.
- Runner health belongs to `docs/development/self-hosted-runner-incidents.md`
  and concerns the release and agent-execution lanes, not perf.
- On PRs, local evidence plus build/test is merge-critical.

## Outputs To Produce

When this skill is used successfully, produce:

- canonical `summary.json`
- short human-readable summary
- before/after delta report when comparing changes
- explicit classification of any infra-only failure

## Guardrails

- Do not bypass `contract.json` with custom thresholds.
- Do not compare different scenarios as if they were equivalent.
- Do not claim a regression from one noisy run when a lower-variance scenario is available.
- Do not treat missing installed-build metrics as product failure before checking Ghostty resources and display/session constraints.
- Do not mix root-cause debugging with contract validation unless the standardized run has already classified the regression.

## Canonical Files

- `config/performance/contract.json`
- `scripts/perf-runner.sh`
- `scripts/perf-compare.py`
- `scripts/verify-installed-perf.sh`
- `scripts/perf-baseline.sh`
- `scripts/new-workspace-perf.sh`
- `.github/workflows/release.yml`
- `docs/decisions/perf-measurement-laptop-optin.md`
- `docs/performance-testing.md`
- `docs/performance/dashboard.md`
- `docs/performance/metrics-reference.md`
- `docs/development/self-hosted-runner-incidents.md`
