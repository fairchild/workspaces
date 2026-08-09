# Launch bimodality after #1276 (2026-08-08)

Characterises the residual `launch_to_first_prompt` cost #1276 left behind on the debug
lanes, under a protocol that controls the state axes the earlier passes could not. The
short version: the residual is a discrete step of a few hundred milliseconds that fires on
most launches, it is not the continuity manifest, and it is not machine noise.

## Protocol

Three axes decide what a launch does before the first prompt, and all three are now pinned
or reported per sample:

| Axis | Control |
|---|---|
| SwiftData store + SQLite sidecar | `WORKSPACES_DATA_DIR`, per invocation (unchanged) |
| `UserDefaults` (terminal continuity manifest) | `WORKSPACES_PREFERENCES_SUITE`, scratch suite the lane owns, wiped per sample under `--preferences clean` |
| Machine occupancy | each sample gates on no live debug instance, and records the 1-minute load average it launched under |

Each sample also reports which path seeded the first session and what it seeded
(`[Perf] event=initial_host_session caller=… branch=… sessions=…`), so a duration is read
against a known launch rather than against an assumption. Captures: `perf-baseline.sh 10 8`,
Mac16,13, pinned Ghostty resources, clean shell profile.

## The manifest branch does not select the mode

The leading hypothesis after #1276 was that restoring 2 sessions rather than seeding 1
decided which mode a launch landed in. Two adjacent 10-sample arms at comparable load —
`--preferences clean` (every sample seeds one fresh shell) against `--preferences carry-over`
(sample 1 seeds, samples 2..N restore two sessions) — say otherwise:

| branch | n | min | median | mean |
|---|---|---|---|---|
| `fresh_seed` (1 session) | 11 | 681 ms | 902 ms | 1056 ms |
| `manifest_restore` (2 sessions) | 9 | 556 ms | 905 ms | 999 ms |

Three milliseconds apart. The manifest state is not the mode selector, and this is a direct
per-sample correlation rather than an argument about the shape of a distribution.

Those arms ran at load 6–12, where duration and load correlate at r = 0.60 (n = 20) — enough
noise that the *absolute* numbers there mean little, which is why the arms are compared to
each other and not to the reference.

## On a quiet machine both lanes are bimodal

`debug_no_activate`, 10 samples, load 2.81–3.95 (median 3.65), every sample
`caller=prologue branch=fresh_seed sessions=1 isolated=true`:

```
813.65  878.53  838.12  549.11  831.41  829.54  865.20  550.21  817.15  839.11
```

Two clusters: **549–550 ms (2/10)** and **813–879 ms (8/10)**. Median 830.47, p95 878.53.

`debug_activate`, 10 samples, load 3.53–5.24 (median 4.63), same constant labels:

```
1011.61  594.22  1035.89  1028.19  541.74  1032.58  1030.53  532.23  532.80  551.38
```

Two clusters again: **532–594 ms (5/10)** and **1011–1036 ms (5/10)**. Median 802.91.

Within each capture the bootstrap branch, the seeding path, the preferences state, and the
machine load are all constant. The split survives all of them.

## What this rules out, and what it points at

Ruled out as the mode selector: the continuity manifest and how many sessions it restores;
which launch path seeds the session (the prologue won every sample in both captures, fast
and slow alike); the preferences domain; machine load. Also not the 100 ms
`TerminalWindowController.fallbackRetryDelay` — the step is far larger and that retry serves
a different window.

The clue worth carrying forward is that **the step size differs by lane while the fast mode
does not**. The fast mode sits at ~550 ms in both lanes; the slow mode is ~830 ms without
activation and ~1030 ms with it. A fixed timer would add the same amount in both. A wait on
an event — the window becoming key, first-responder assignment, surface realization landing
in a later run-loop pass — would take longer exactly where activation puts more work in
front of it. That is a hypothesis, not a finding; the next pass instruments the first-layout
and surface-realization path rather than guessing a fourth time.

## Reference consequences

- `debug_no_activate` `launch_to_first_prompt` keeps **592 / 631**. The fast mode reproduces
  it on this build, so the reference is achievable and the failing median is a live defect,
  not a cost to re-baseline away. `--assert-budget` stays red on this metric, honestly.
- `debug_activate` `launch_to_first_prompt` moves from **220 / 300** to **592 / 631**. The
  220 ms seed was never achievable — it claimed the activating lane was faster than the
  non-activating one — and the capture shows the two lanes measure the same cost (fast modes
  550 vs 542 ms, medians 830 vs 803 ms). One behaviour, one reference.
- `debug_activate` `repo_click_to_focus` keeps **220 / 300**: measured median 176.40 ms,
  p95 193.37 ms across 10 samples. Validated, not changed.
- `repo_hydration` keeps **20 / 30** on both lanes: measured median ~1.4 ms.

Rows in `metrics-history.csv` from before 2026-08-08 came from a lane whose `UserDefaults`
domain was not isolated. Compare across that boundary with care.
