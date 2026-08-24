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
activation and ~1030 ms with it. A fixed timer would add the same amount in both; a wait on
an event would not.

## Where the step actually is (2026-08-09)

The first-layout hypothesis above is **falsified**, and it did not need new instrumentation
to falsify — the captures already contained the answer. Every sample in both lanes ends on
`trigger=terminal_set_title`, so the interval always closes the same way, and aligning a fast
run's log timeline against a slow one shows them identical to within ~20 ms through
`surface_create_succeeded`. The entire gap appears afterwards.

Correlating per sample:

| lane | pearson(`launch_to_first_prompt`, first shell's `terminal_first_output`) |
|---|---|
| `debug_no_activate` | r = 1.000 (n=10) |
| `debug_activate` | r = 1.000 (n=10) |

All of the launch variance is the first shell's time to first output. Surface creation itself
is constant (~390 ms in both modes); the split lives entirely between
`surface_create_succeeded` and the shell's first byte — ~103 ms in the fast mode against
~416 ms in the slow one.

Two things narrow it further:

- **The second shell never pays it.** The repo-selection session created ~100 ms later in the
  same process reaches first output in 89–120 ms (no-activate) and 137–174 ms (activate),
  every sample, with no bimodality. Whatever this is, it is a first-surface cost.
- **It is not the shell.** Clean profile mode spawns `/bin/zsh -f` — no rc files at all.
  Spawning exactly that under a PTY outside the app, 20 samples, gives 7–69 ms with a median
  of 22 ms and one mode. zsh is three orders away from explaining a 300 ms step.

So the residual is inside the app's own surface-to-first-byte path: after libghostty reports
the surface created, the first PTY's first byte arrives either ~100 ms or ~420 ms later, and
only for the first surface of the process. Ruled out at this point: the continuity manifest,
the bootstrap branch, which path seeded the session, SwiftUI's first layout pass, surface
creation, machine load, and the shell.

The next probe belongs inside that window — when libghostty actually forks the PTY relative
to `surface_create_succeeded`, and when its read loop is first scheduled. Distinguishing "the
child is forked late" from "the child is forked promptly and its output is delivered late"
is the fork in the road, and neither is observable from the logs the app emits today.

## Where the step comes from (2026-08-23)

The fork-vs-deliver question above is answered: neither. `LaunchWindowProbe`
(diagnostics-gated, `WORKSPACES_TERMINAL_DIAGNOSTICS=1`) timestamps the child spawn from
the process table, every libghostty wakeup, the wakeup→tick MainActor hop each delivery
rides, and a 25 ms main-queue heartbeat. A 10-run `debug_no_activate` capture says, per
sample:

- **The child is forked promptly and read promptly.** The shell appears in the process
  table ~10 ms after `surface_create_succeeded`, and wakeups arrive steadily from then on
  (max gap between consecutive wakeups ~35 ms). Nothing on the libghostty side is late.
- **The entire step is the wakeup→tick hop.** `launch_to_first_prompt` ≈ ~600 ms fixed
  (surface create ~490 + first OSC ~110) plus the MainActor scheduling latency of the tick
  that delivers the first title action: hop 0 ms in the one fast sample, 170–413 ms in the
  nine slow ones, correlation by inspection exact.
- **The main thread services nothing until bring-up drains.** The heartbeat timer, armed at
  launch begin with a 25 ms period, fires for the first time at 767–1004 ms — immediately
  followed by every queued tick and the title delivery, all within ~2.5 ms. The launch
  window is wall-to-wall main-thread work; GCD and Swift-Concurrency jobs alike wait it out.
- **The fast mode was an artifact, not a fast launch.** In the fast sample the delivering
  wakeup fired *on the main thread* (libghostty invoked the callback from inside a call the
  app made mid-bring-up), took `runOnMainAsync`'s inline branch, and closed the metric at
  618 ms — while that same sample's queued ticks show the main thread stayed busy until
  1041 ms. The metric closed; the app was not yet usable.

A `sample(1)` profile of the launch window attributes the bring-up itself: SwiftUI's
initial window construction (`showInitialWindows` → `NSWindow` init → Metal device
enumeration ~116 ms → toolbar bridge + text engine first-use ~150 ms) plus AppKit menu
setup soft-linking WritingToolsUI (~134 ms) — framework first-window cost in an unoptimized
debug binary, not work any June–August arc added. The bisect's earlier finding stands
unchanged (#684 added ~140 ms of the same class, removed by #1276); the rest of the
592→~1500 gap is this bring-up cost growing with binary size, framework versions, and
machine load, measured honestly only when the delivery lottery loses.

**Fix shipped with this finding:** the wakeup callback now always enqueues its tick
(`GhosttyThreadingBridge.enqueueOnMain`) instead of running it inline when it happens to
land on the main thread. Upstream Ghostty.app dispatches its wakeup tick async for the same
reason — an inline `ghostty_app_tick` from inside another libghostty call re-enters the
core mid-call. This removes the re-entrancy hazard and the artifact: every sample now
closes at main-drain time, one mode, honestly.

## Reference consequences (2026-08-08, superseded)

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

## Reference consequences (2026-08-23, current)

The 2026-08-08 decision to keep 592/631 rested on "the fast mode reproduces it, so the
reference is achievable." The probe shows the fast mode closed the metric while the main
thread was still mid-bring-up — the reference was reproducible only by the artifact, and
with the artifact removed no honest sample can reach it on this build. Per the refresh
protocol, both debug lanes' `launch_to_first_prompt` references are re-derived from 10-run
captures on the fixed build (Mac16,13, load 1m ~4, every sample
`prologue`/`fresh_seed`/`isolated=true`):

| lane | samples (ms) | new reference (median / p95) |
|---|---|---|
| `debug_no_activate` | 771–1404, median 892.28 | **892 / 1404** |
| `debug_activate` | 976–1686, median 1181.22 | **1181 / 1686** |

The lanes diverge again deliberately. The 08-08 unification ("one behaviour, one
reference") described two artifact-mixed distributions that happened to align; with the
delivery lottery removed, activation's extra main-thread bring-up (~290 ms at median) is
honestly visible, and blessing it under a shared reference would hide an activation-lane
regression behind no-activate headroom. Debug lanes remain branch-delta and trend lanes,
not release signoff; the release path (`installed_clean_shell`, 288 ms measured against a
640 ms reference on 2026-08-07) was never affected. Rows in `metrics-history.csv`
predating the artifact fix mix delivery-lottery modes; compare across 2026-08-23 with the
same care as the 08-08 isolation boundary.
