# Perf measurement moves to the laptop, opt-in per run

**Date**: 2026-08-08
**Status**: accepted
**Decided by**: repo owner (fairchild)
**Issue**: [#1240](https://github.com/fairchild/workspaces/issues/1240)

## Decision

> "lets run smoke lane on github runner or xcodecloud, and run perf benchmark on
> my laptop with an approval gate"
> — owner, [#1240](https://github.com/fairchild/workspaces/issues/1240)

Two lanes, split by what each one actually needs:

- **Behavioral UI smoke** runs in the cloud, on GitHub-hosted `macos-26`
  (`.github/workflows/ui-smoke-advisory.yml`). Whether it becomes a required
  status is [#1229](https://github.com/fairchild/workspaces/issues/1229) and is
  unaffected by this decision.
- **Perf benchmarks** run on the owner's laptop, opt-in per run. There is no
  schedule and no runner-lane dependency. The owner approves each measurement
  session; an agent or the owner then executes the protocol below.

`.github/workflows/perf-validation.yml` (the daily 09:00 cron) and
`.github/workflows/tart-ui-smoke.yml` are deleted. The `[self-hosted, tart-ui]`
lane is retired — nothing in CI targets it.

## Why

**The lane never worked.** Across 160 `perf-validation.yml` runs
(2026-03-25 → 2026-08-07): 129 skipped, 30 cancelled, 1 failure, **0 successes**
of the measurement job. The one non-skip (run 24276742535, 2026-04-11) died in
ten minutes with no steps recorded. `docs/performance/metrics-history.csv` ends
2026-03-22 with only locally-captured `Mac16,13` rows — every number in the
dashboard's history came from a laptop, never from this lane. Reviving it meant
debugging a lane with no working precedent, not re-provisioning a known-good one.

**Hosted runners cannot carry these budgets.** The contract's gates are
`median × 1.25` derived on `Mac16,13 / M4`. A budget is a claim about specific
hardware; running it on different hardware measures the runner, not the product.
Xcode Cloud was evaluated for this and disqualified: Apple publishes no machine
type, cores, or RAM and offers no selection, so the budgets have no stable
denominator. Independent blockers even if that were solved — Xcode Cloud deletes
files created by `ci_scripts` and excludes them from downloadable artifacts, so
`summary.json`, the history CSV, and the dashboard have no exit path; there is a
~30-minute no-stdout-activity timeout; and whether the build environment has a
WindowServer session is undocumented. All perf scenarios except the four channel
ones launch the real GUI app through `launch-dev.sh`'s
`CGWindowListCopyWindowInfo` visible-window gate, so a session-less environment
cannot run them at all.

**The laptop is the machine whose performance matters.** This is a Mac-native
app used on a developer Mac. A number captured there is the number a user
experiences; a number captured on a 3-core hosted M1 is a proxy for nothing we
ship.

### Keep the lesson that the deleted cron encoded

The cron's final form was deliberately loud: when the lane was absent it **failed
the run on purpose** rather than skipping green. That behavior came from
[#1238](https://github.com/fairchild/workspaces/issues/1238) — before it, a
skipped measurement job reported success daily, and a dead lane stayed invisible
for weeks while the schedule looked healthy.

**A skipped measurement must never be indistinguishable from a passing one.**
That rule survives the workflow that carried it, and it constrains the
replacement: the opt-in protocol has no green-by-default state at all, because
nothing runs unless someone runs it. Staleness is read off a visible date (see
below) rather than inferred from a run that quietly did nothing.

## What replaces the cron

### Trigger

The owner approves a measurement session. There is no schedule. Reasonable
prompts to ask for one: a performance-sensitive PR, a re-baseline after a launch
path change, or the dashboard's `Last updated` date having drifted further than
the current question tolerates.

**Staleness is read from `docs/performance/dashboard.md`'s `Last updated`
timestamp**, not from a cron's colour. If the dashboard is old, the honest
statement is "the last recorded measurement is from `<date>`" — not "perf is
green" and not "perf is failing".

### Protocol

Run from the repo root on the owner's laptop, after the preconditions below.

1. **Launch lanes + record** — the same command the cron ran:

   ```bash
   ./scripts/perf-baseline.sh 3 6 --record --assert-budget
   ```

   `--record` appends to `docs/performance/metrics-history.csv`, refreshes
   `docs/performance/latest-summary.json`, and regenerates
   `docs/performance/dashboard.md`. Commit those three files as part of the
   session's output — that commit is what makes the next staleness read honest.

2. **Main-window hot-spot scenarios** — every scenario runs even after a failure,
   so one budget miss cannot hide the rest:

   ```bash
   for scenario in \
     main_window_agent_activity_burst \
     main_window_session_switcher_snapshot \
     main_window_workspace_create_ui_stall \
     main_window_idle_cpu_diagnostics_closed \
     main_window_resident_memory_20_workspaces
   do
     ./scripts/perf-runner.sh --scenario "$scenario" --assert-budget \
       --output-dir "perf-artifacts/$scenario" || echo "FAILED: $scenario"
   done
   ```

3. **Channel scenarios** — plain `swift test` workloads, no GUI launch
   (`channel1_long_session_memory` is a ~10-minute soak):

   ```bash
   for scenario in \
     channel1_hook_ingest_burst \
     channel2_statusline_burst \
     channel1_sidebar_churn \
     channel1_long_session_memory
   do
     ./scripts/perf-runner.sh --scenario "$scenario" --assert-budget \
       --output-dir "perf-artifacts/$scenario" || echo "FAILED: $scenario"
   done
   ```

4. **Report every scenario's verdict**, including the ones that passed. A
   session that reports only failures is indistinguishable from a session that
   only ran the failing scenario.

To append an ad-hoc canonical summary without re-measuring:

```bash
uv run --script scripts/perf-history-record.py --summary <output-dir>/summary.json
```

### Measurement hygiene (proven 2026-08-08 on [#1251](https://github.com/fairchild/workspaces/issues/1251) / [PR #1276](https://github.com/fairchild/workspaces/pull/1276))

These three rules are what separated the valid 2026-08-08 measurement from the
invalidated attempt before it. They are preconditions, not suggestions.

**Per-sample kill gate.** Every sample ends with: SIGTERM the launched PID → 1 s
grace → SIGKILL → then `pgrep -f 'debug/WorkspaceManager'` **must return empty**
before the next launch starts. A sample that begins with a previous instance
still alive is void, not slow. The 2026-08-08 session ran 10/10 valid samples
with every gate clean under this rule.

This guards a live harness defect:
[#1277](https://github.com/fairchild/workspaces/issues/1277) —
`scripts/perf-runner.sh` leaks one live `WorkspaceManager` per lane. Leaked
instances accumulate across runs, progressively load the machine, and corrupt
the timings the harness exists to produce. Until #1277 lands, sweep manually
after every `perf-runner.sh` invocation. (Construct the binary path in the
script rather than writing the pattern as a literal, so `pgrep` never matches
the harness's own argv.)

**Quiet-machine precondition.** Check the 1-minute load average before starting
and record it in the report. The 2026-08-08 session waited for 1-min load below
4.0 and still observed 3.1–4.2 at individual launches on a developer desktop
with ambient GUI load — which is exactly why the number goes in the report: it
bounds how much of an observed delta the reader should believe. Close agent
sessions, builds, and browsers first; a laptop measurement is only better than a
hosted one if the laptop is actually quiet.

**UserDefaults isolation.** Set `WORKSPACES_SYNTHETIC_ROOT` (or
`WORKSPACES_PREFERENCES_SUITE`) on isolated launches. `WORKSPACES_DATA_DIR`
scopes the SwiftData store and the SQLite sidecar but **not** preferences: before
[#1258](https://github.com/fairchild/workspaces/pull/1258) a launch with a clean
data dir still restored `mainWindow.lastSurface` from the persistent
`WorkspaceManager` domain and attached a terminal for the previous session's
path, ahead of anything the driver did
([#1252](https://github.com/fairchild/workspaces/issues/1252)). That attach lands
inside the `launch_to_first_prompt` interval. The fix is merged but inert unless
the isolation variable is set, so setting it is part of the protocol.

## Consequences

- No scheduled perf signal exists. Regressions are caught when someone measures,
  not automatically. This is the accepted cost: the previous "automatic" signal
  measured nothing for four and a half months while reporting daily.
- `docs/performance/metrics-history.csv` gains rows only from laptop sessions,
  which is what it already contained — the trend line stays on one hardware
  profile rather than mixing runner classes.
- Budgets stay `Mac16,13`-derived. Nothing off-host may assert them; an off-host
  run of the four channel scenarios is advisory at best.

## Reopening

If a scheduled perf lane is wanted again, the bar is dedicated hardware matching
the budget denominator (`Mac16,13`-class), plus one manually dispatched run that
completes the measurement job end to end before anything is put on a schedule.
Standing up a schedule ahead of a proven run is what produced 160 runs and zero
measurements.
