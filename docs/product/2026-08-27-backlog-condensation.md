# Backlog condensation — decision record

> **As of 2026-08-28.** Approved in full; **not yet executed.**
>
> Michael approved three decisions on 2026-08-27: refill the milestone layer,
> take a batch of 7 merges and 13 closures, and defer the factory-autonomy call
> to a metric. None of it has run — `gh` cannot open a network socket on this
> machine, and every tracker write needs it.
>
> **Staleness test, in order:** if `[D4]`, `[A3]` and `[F2]` are open milestones
> on GitHub, this record is history and the tracker is the truth. If they are
> not, nothing here has been executed and the backlog still looks the way § 1
> describes it. Either way, re-read § 1's numbers against `gh issue list` before
> planning from them — the tracker lags this file the moment anything ships.

Produced by the product-triage persona (Mara Fielding) from the 2026-08-27
check-in sweep. The reasoning behind each call, with per-issue evidence, is in
the sweep briefing; this file is the decision, not the argument.

---

## 1. What the sweep found

**The backlog reads unthemed because the layer meant to carry the themes is
empty.** `backlog/ROADMAP.md` was deliberately rewritten to direction-only in
#1214 and now states that current focus reads off the open milestones.
`[H2] Self-Validation & Hardening` closed on 2026-08-24 carrying 46 issues, and
no successor opened. The result, measured 2026-08-28:

| | |
|---|---|
| Open issues | 91 |
| Carrying no milestone | 90 of 91 |
| Open milestones | 1 (`[F1]`, holding 1 issue) |
| Feedback store, unpublished rows | 0 |

This is not drift. The roadmap points at exactly the right surface; the surface
is empty.

**The `ready` queue was never a backlog.** `ready` is the factory's admission
token, not a priority signal. The 19 issues carrying it were released to a loop
that had never completed end to end until 2026-08-27 (#1110 S1, third attempt).
Two verified causes for the stall: the loop did not work, and
`verify_release_actor` refused bot-restored `ready`, which 5 of the 19 carried.
#1387 fixed three of those lineage shapes retroactively; **#1271 and #1366 still
will not admit** and need a manual label cycle.

---

## 2. The rule

> **We execute what makes the loop finish without the owner, and what makes the
> terminal trustworthy. We sunset what serves a user who does not exist yet.**

Two tests, applied in order:

1. **Core-loop test** — does it change *pick context → get a terminal → work*?
   Then it is D lane and outranks everything else.
2. **Autonomy test** — does it reduce owner turns per merged PR? Then it is F
   lane, and it is measurable.

Anything failing both is breadth. Breadth is `idea`, or it is closed. This is
what makes § 5's closure list a rule rather than a mood, and why A is active
(the operator plane carries evidence for both tests) while W is frozen.

---

## 3. Milestone posture

One active milestone per lane, per the operating contract in
`docs/agents/issue-tracker.md`.

| Lane | Milestone | Posture | Contents |
|---|---|---|---|
| D | `[D4] Terminal trust` | ACTIVE | #889 (root), #1267, #1356, #1359, #1390, #845, #895, #892 |
| D | *(none — carryover)* | — | #1366, #1368 finish out of the ready queue; #1367, #1369 wait |
| A | `[A3] Operator plane: one owner, many instances` | ACTIVE | #1362, #1330, #1279, #1278, #1262, #1227, #973, #1385 |
| F | `[F1]` → closed; `[F2] Factory autonomy` | ACTIVE | #1125 (headline, deferred to the metric), #1386, #1271, #1208, #1079, #1088 |
| W | *(none)* | FROZEN | Next move is the folio repository split, not the six open web issues |
| ops | *(none)* | — | #1385 rides in `[A3]`; #1343, #1305, #1309, #938, #1223, #1352 unmilestoned |

**The D-lane fork, resolved.** Terminal trust goes active ahead of the #1347
perf residual, because tiles launching as plain shells is the core promise
failing and perf is refinement. The cost: #1367 and #1369 wait.

**`[A3]`'s independence argument** (required when a second lane runs concurrently):
it touches `Sources/…/Automation*`, `scripts/`, and `.github/` — not the terminal
and tile surfaces D touches. Distinct files, distinct reviewer context.

---

## 4. Merges — 19 issues into 7

Absorbed acceptance criteria are copied into the surviving issue **before**
anything closes.

| Into | Absorbs | Why |
|---|---|---|
| #889 | #1266 | Probable root and the symptom that proves it |
| #1267 | #1295 | One tmux kill-authorization defect, two criteria |
| #1219 | #1220, #1221 | Same 2026-08-06 exploration pass, all small UI |
| #1033 | #1306, #1316, #1370, #1321 | Five flakes too small to claim alone; together one green result |
| #1362 | #1391 | #1391 is the observed failure of #1362's root — a process-global credential |
| #517 | #518 | Two halves of the same first-run trust for the agent integration |
| #1139 | #1140, #1141 | Three speculative "factory improves itself" ideas filed the same day |

## 5. Closures — 13

Each closes with its reason in the closing comment, naming what was met and
where anything live relocates.

| Issue | Reason | Kind |
|---|---|---|
| #1375 | Shipped 2026-08-27 in #1392 | done |
| #1229 | `tart-ui` deregistered; `actionlint.yaml` allows zero self-hosted labels; the lane already runs on `macos-15`. **Relocate** "make ui-smoke-advisory required" as its own issue | premise |
| #706 | Native diff editor shipped in #713/#720; `pierre` appears nowhere in the tree | premise |
| #6 | No code footprint, no comments in 200 days — an IDE feature, not a core-loop one | breadth |
| #7 | Git operations from the UI serve a user who does not exist yet | breadth |
| #872, #873, #874 | Parity with another tool is not a product goal; tile-tree epic #627 closed complete | breadth |
| #836, #837 | Breadth on a one-user feature with no evidence of use; `RaceGroupPlanner` stays | breadth |
| #552 | Tooling breadth — the checking apparatus becoming its own project | breadth |
| #532, #555 | Side systems unmoved since May; priority rule 3 says they wait. `DaytonaBackend.swift` stays and keeps working | rule |

**Park, do not close:** #944 (`CGWindowListCreateImage` still works — real when it
breaks) and #721 (live TestFlight intent behind it).

## 6. Net effect

| | |
|---|---|
| Open now | 91 |
| After 13 closures | 78 |
| After merges absorb 12 | 66 |
| Remaining `idea`, filtered from working views | 9 |
| **Working backlog, in six themes** | **57** |

## 7. `ready` queue dispositions

8 re-release · 5 merge into 2 · 5 park (drop `ready`) · 1 verify.

| Issues | Disposition | Note |
|---|---|---|
| #845, #976, #530, #882, #1305, #1309, #517(+#518), #1343 | Re-release | #976 first — a green gate that did not run is worse than a red one. #882 will park on evidence unless #1088 lands first |
| #1033, #1321 | Merge into the flake sweep | |
| #938, #999, #1044, #1046 | Park — drop `ready` | Human-lane, or presupposing frozen W-lane breadth |
| #958 | Verify first | Check overlap against #1392's `automation repo terminal` |
| #1271, #1366 | **Owner label cycle required** | Admission lineage cannot be repaired by the factory |

---

## 8. The metric, and what it decides

**Owner turns per merged factory PR.** As of 2026-08-27: **0 of 1** — #1377
needed an attestation, a review dismissal, and an owner approving review. That is
the entire sample; the loop has completed once.

The refine lane (#1378–#1382, all five merged as of 2026-08-27) made owner
blocking *narrower and louder*. None of it makes April fix a rejection — #1383's
own PR body states there is deliberately no "you are not needed" outcome. The
unbuilt half is #1125.

**Pre-committed threshold:** after the next ten factory PRs, if fewer than half
reach merge without an owner turn, #1125 is required and M4 opens. If most do,
#1383's conservative escalation is the right end state and #1125 closes with that
reasoning recorded. Decided by evidence, rather than by nobody opening a
milestone.

---

## 9. Open owner actions

- Cycle `ready` on **#1271** and **#1366** by hand.
- **#547** — the roadmap names it as a gate ("notifications should catch up
  reliably before they get more entrypoints"). It has no milestone and has not
  moved since May. Promote it, or take the sentence out of the roadmap.
- **#1110** — the merge-authority contract still reads *pending owner decision*
  after S1 and S2 both passed.
- **`gh` cannot dial.** Little Snitch is running; a freshly compiled Go binary
  reaches `api.github.com:443` fine, and `curl` and a raw socket both succeed, so
  Go networking is healthy and something denies `gh` specifically. Stable 2.96.0
  and `HEAD-d76da60` fail identically, so whatever the rule matches on is broader
  than a build hash. Gesture: open Little Snitch, delete or allow the `gh` rules.

---

## Provenance

Sweep run 2026-08-27 against `origin/main` at `7af1e271`; figures in § 1 and § 6
re-measured 2026-08-28 against `b0c7b0cd`. GitHub reads went over `curl` with a
local token because `gh` could not dial. Nothing in this record has been executed
against the tracker.
