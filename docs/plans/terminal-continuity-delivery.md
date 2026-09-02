# Terminal continuity: fix delivery before extending the ladder

Plan, 2026-08-31. Status: proposed, nothing started. Claims verified against
this repo at `9da54db1` and against a captured restart of the installed build
(v0.26.0) on 2026-08-30 at 21:32 local.

**Staleness test**: run `ps -Eww` on the shell of any Terminal Session restored
at launch and grep for `WORKSPACES_HOST_SESSION_ID`. If the variable is
present, S1 has landed and this document's premise is stale — re-verify
§ "What the capture showed" before acting on anything below.

## Summary

Cold-start restore decides correctly and then fails to deliver. The restore
ladder planned 15 Terminal Sessions and chose the `reattachTmux` rung for 12 of
them. Every tile surface it created launched as a bare login shell: no tmux, no
environment, no agent. The live tmux sessions holding the user's work sat
untouched beside them.

The cause is filed as #889 — libghostty drops per-surface launch configuration —
and the issue is filed narrower than the defect. Fix delivery first. Every other
slice in the `arc:terminal-continuity` backlog is untestable until a restored
tile surface can be configured at all.

> **Correction, 2026-09-02 (#1520).** The observations below stand; the
> attribution in this paragraph does not. The Swift-to-C marshalling seam is now
> pinned by `GhosttyTerminalConfigTests.cValueCarriesEveryPerSurfaceField`, and
> staged spawn-layer runs delivered `command`, `env_vars`, and
> `working_directory` to every surface. What remains unexplained is the capture
> recorded here, whose loss point no later run has reproduced. Read "the cause is #889" as "the symptom is tracked by #889",
> with the loss point unknown.

## What the capture showed

A `log stream` on subsystem `com.cloudcompute.workspaces` was running across a
real app restart. Relevant lines:

```
21:32:48  [Restore] planned 15 restorable surface(s)
21:32:55  [Restore] executed 15 surface(s)
21:32:56  [Reattach] trigger=restore candidates=12 rejoined=9
```

Twelve of the 15 `[HostSession] Created restored session` lines carry
`adopted=true`, which `MainWindowRestoreController.adoptedHostSessionID` sets
only on the `reattachTmux` rung. Zero `[SurfaceStore] initial command` lines
appeared, so the `resumeClaude` rung delivered nothing.

Ten restored tile surfaces materialised. Each launched in the correct working
directory and each is a bare `zsh`:

| Observation | Restored tile surface | Tile surface opened later by hand |
| --- | --- | --- |
| `working_directory` applied | yes | yes |
| `command` applied (tmux attach script) | no | yes |
| `TERM`, `COLORTERM` | absent | present |
| `WORKSPACES_HOST_SESSION_ID` | absent | present |
| `WORKSPACES_HOOKS_SOCKET` | absent | present |
| attached to its tmux session | no | yes |

Checked on five restored shells and two hand-opened controls. Meanwhile 25
tmux sessions on the `-L workspaces` socket held live Agent UIs, and only the
hand-opened ones were attached.

**This widens #889.** The issue records that `command` and `initial_input` are
missing on surfaces created after the app's first. Environment variables are
missing too. The issue does not say so, and the distinction matters: an
unconfigured environment is what breaks agent identity. ("After the app's first"
describes what was observed in that capture, not a keying rule anyone has
demonstrated — see the correction above.)

## Why it matters: one defect, three faces

A Terminal Session restored without `WORKSPACES_HOST_SESSION_ID` cannot tell
the hook listener who it is. So no `agent_status_events` row records an
`agent_session_id` for it. So the `resumeClaude` rung, which reads that column,
can never fire for it on the next restart. So the tile comes back empty again,
records nothing again, and stays empty.

The empty terminals, the missing session ids, and the intermittency the owner
described as "mostly works but not always" are the same defect observed at
three distances. `working_directory` surviving is what makes restore look
half-successful instead of failed.

A second, smaller defect sits behind the same symptom.
`LocalStateStore.fetchPreviousRunSessions` joins the *newest*
`agent_status_events` row per Terminal Session. 396 of 1306 `osc`
`awaiting_input` events carry a null `agent_session_id`, and `awaiting_input` is
the state an Agent sits in when the app quits. A session whose id is known from
an earlier event loses it to the join. Real instance at capture time:
`~/workspaces/folio/server` knew `809d2e6a-d8cf-4dfc-8c6b-4ef3d862c980` and the
join returned null.

### Ruled out

Restore is not gated on an unclean exit. `applicationWillTerminate`
(`WorkspaceManagerApp.swift:666`) stops the embedded web-next server and touches
no Terminal Session row. The `is_active = 0` pattern on older runs is
`LocalStateStore.endStaleSessionsFromOlderRuns` (#1347 D4), a launch-time
sweep that deliberately protects the current run and the single restorable
prior run.

## Goal

A restart is a non-event for work that is still alive, and a single keypress
for work that is not.

The principle that gets there: **restore reconnects; it never starts.**
Attaching a live tmux session costs nothing, because the process is already
running and its context is already paid for. Starting an Agent costs memory and
tokens. So the `reattachTmux` rung runs automatically and silently, and the
`resumeClaude` rung prefills its command and waits for the user to press Enter.

Done looks like: anything still running comes back attached; anything that died
comes back with its exact resume command already at the prompt; the user can see
what restore decided per Tile and why; and a test fails when this breaks again.

## Slices

### S0 — Correct the record on #889

Amend #889 with the environment-variable finding and this capture. Cheap, and
it unblocks anyone reasoning from the arc. #1418 currently states the opposite
premise — "App restart needs none of this (the server outlives the app)" — and
app restart is exactly where this fails.

### S1 — Reliable delivery (keystone)

Stop treating per-surface launch configuration as trustworthy. After a tile
surface reports alive, assert the launch contract: expected environment marker
present, expected tmux session attached. On failure, deliver over the automation
text bridge, which is already the shipped mechanism for `initialCommand`
(`SurfaceStore.deliverInitialCommandIfNeeded`). Log the outcome either way, so a
silent drop becomes a visible counter instead of an empty terminal.

Verify first rather than always typing: typed delivery is visible to the user
and races shell startup, so the fast path should keep its win when it works.

Acceptance: every restored Terminal Session either carries its environment and
its tmux attachment, or logs exactly why it does not.

### S2 — Identity that survives the app being dead

Three parts. Add #1417's `$HOME`-fixed hook-written state file, so an Agent
session id recorded while the app is down is not lost. Fix the
`fetchPreviousRunSessions` join to take the newest *known* `agent_session_id`
rather than the newest row. Add a transcript fallback that resolves a working
directory's newest transcript when no id was ever recorded, which is what the
owner does by hand today.

S1 is a prerequisite: with the pane environment restored, hooks work again while
the app is up, and the state file covers only the window where it is not.

### S3 — Lazy resume

The `resumeClaude` rung types `claude --resume <id>` and stops — drop the
`sendAutomationReturn` call. Two questions settle inside this slice. What to
prefill when no id is recorded (proposal: the newest transcript for that working
directory, de-duplicated across Terminal Sessions sharing one directory, because
duplicates exist in practice). And how to reconcile with
`MainWindowOpenSurfaceReattachController`, which today excludes any session
carrying an `initialCommand` because re-running an Agent is "an explicit act,
not restore" — a prefill is not a run, so that rule must distinguish the two.

### S4 — Legibility

Show per Tile what restore did and why. Add a `workspaces resume-command [dir]`
CLI verb that prints the exact command for a directory: an escape hatch when the
UI is wrong, and a durable answer to "what do I type here".

### S5 — Regression gate

`scripts/continuity-evidence.sh` already runs an app-restart lane with launch,
capture, and a summary. Extend it to assert the S1 contract per restored
Terminal Session, and add the reboot-shaped lane #1418 asks for
(`tmux -L workspaces kill-server` plus relaunch approximates a reboot without a
logout). Without this, the next #889-class drop is invisible again.

### S6 — Document and graduate

One page describing the ladder and the guarantee it makes, then enable
`restoreSessionsOnLaunch` by default once the lane is green. Closes #1418.

## Decisions taken

**The `reattachTmux` rung attaches silently at launch; the banner is for rungs
that need a decision.** Reconnecting to a running process costs nothing, so
asking about it spends the user's attention for no benefit. The banner earns its
place only when restore would start something.

**Delivery ships as a standalone bug fix, not as part of #1418.** S1 is a defect
with a mechanical test. #1418 is a feature carrying a product decision. Coupling
them would gate a correctness fix on a taste question.

## Dependency order

S0 and S1 first; S1 gates everything. S2 next, because S3's prefill is only as
good as the id it prefills. S3 and S4 are independent of each other. S5 can be
written against S1 as soon as S1's contract is defined. S6 last.

## Slice to issue

| Slice | Issue | State |
| --- | --- | --- |
| S0 — correct the record | #889 | done 2026-08-31 (comment + title) |
| S1 — reliable delivery | #1478 | ready |
| S2 — identity | #1480, plus #1417 | #1480 ready |
| S3 — lazy resume | #1481 | queued behind S1 |
| S4 — legibility | #1482 | queued |
| S5 — regression gate | #1483 | queued behind S1's contract |
| S6 — document and graduate | #1418 | blocked on S5 |

## Related issues

| Issue | Relationship |
| --- | --- |
| #889 | Tracks the symptom. Widened by this plan (S0). Called "root cause" when this plan was written; see the 2026-09-02 correction in § Summary — the loss point is unknown. |
| #1418 | Graduation target (S6). Its "app restart needs none of this" premise is wrong; corrected in a comment. |
| #1417 | Half of S2 — ids recorded while the app is dead. #1480 is the other half. |
| #1416 | Launch provenance; informs the S3 offer text, not the executed command. |
| #1398 | `[Reattach] rejoined=` overcounts; observed again here (12 candidates, 9 rejoined). |
| #1449 | Pane environment inheritance; adjacent to the S1 contract. |
| #1267 | tmux teardown safety; the S1 contract must not widen its blast radius. |
| #1360 | Per-terminal agent metadata; neighbouring surface to S4. |
