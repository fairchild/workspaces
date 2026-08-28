# Backlog condensation — decision record

> **As of 2026-08-28.** Approved and **executed**, except the re-release queue.
>
> Milestones `[D4]`, `[A3]`, `[F2]` are open and populated; `[F1]` is closed. All
> 7 merges and all 13 closures are done, each with its reason recorded on the
> issue. The `ready` queue is **not** drained — executing it uncovered a
> different binding constraint than the one this record originally named. See
> § 7.
>
> **Staleness test, in order:** if `[D4]`, `[A3]` and `[F2]` are still the open
> milestones, this record is current. If a `[D5]` or `[A4]` exists, a lane has
> moved on and § 3 is history. Re-read § 1's counts against `gh issue list`
> before planning from them — the tracker leads this file the moment anything
> ships.

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

**The `ready` queue was never a backlog — and the reason it stalled is not what
this record first said.** `ready` is the factory's admission token, not a
priority signal. The 19 issues carrying it were released to a loop that had never
completed end to end until 2026-08-27 (#1110 S1, third attempt). Two causes were
verified up front: the loop did not work, and `verify_release_actor` refused
bot-restored `ready`, which 5 of the 19 carried.

Both were real, and neither is the binding constraint. Executing the re-release
on 2026-08-28 found it: **13 of the 13 re-release candidates have no
`## Requested Evidence` section**, and the admission gate declines without one —
correctly, per #1380's third finding, rather than burning an implement run. #1366
and #1368 were declined within seconds of release, cleanly, with an explanatory
comment.

So the queue could never have drained regardless of the loop or the lineage.
Adding a contract to #1368 and re-releasing it admitted immediately, which
confirms the diagnosis and gives the recipe. This is the good kind of blocked:
the gate is doing exactly its job, and the work is authoring 11 more contracts.

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

## 7. `ready` queue — dispositions and what executing them found

**Executed:** 4 parked (`ready` dropped), #958 verified and kept, admission
lineage repaired on #1366 and #1368 by cycling `ready` as the owner.

**Not executed:** the remaining re-releases. Executing the first two exposed the
constraint in § 1 — every candidate lacks a `## Requested Evidence` section and
is declined at admission. Eleven contracts still need authoring, and each is real
per-issue judgment about what would make the change believable, not a template.

| Issues | Disposition | State |
|---|---|---|
| #1368 | Contract authored, re-released | **Admitted — implementing** |
| #1366 | Contract authored, re-released | **Admitted** |
| #845, #976, #530, #882, #1305, #1309, #517, #1343, #1033, #958 | Re-release, blocked on a contract | Contract needed first. #976 first when they go — a green gate that did not run is worse than a red one. #882 will park on evidence unless #1088 lands first |
| #938, #999, #1044, #1046 | Parked — `ready` dropped | Done |
| #1271 | Held | Bot-applied `ready` with no owner release anywhere in its lineage; needs both a cycle and a contract |
| #518, #1321 | Closed by merge | Done |

**A note on sequencing that cost nothing to learn but would have cost something
to guess at:** releasing several at once during a live release cut would have put
factory-authored PRs into `main` while v0.26.0 was being tagged. The WIP cap
would have limited the damage, but the right order is release-cut first, queue
second.

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

- **#1271** — bot-applied `ready` with no owner release in its lineage. Needs a
  label cycle *and* an evidence contract before it can admit.
- **#547** — the roadmap names it as a gate ("notifications should catch up
  reliably before they get more entrypoints"). It has no milestone and has not
  moved since May. Promote it, or take the sentence out of the roadmap.
- **#1110** — the merge-authority contract still reads *pending owner decision*
  after S1 and S2 both passed.
- **The monitoring gap, newly visible.** Two independent scheduled checks went
  red and stayed red without anyone noticing: #1385 (repo settings drift, failing
  every run since ~2026-08-22 including scheduled `main` runs) and #1404 (the
  production web-next agentic turn producing nothing for four days, while
  recording no error events). A check nobody reads is indistinguishable from a
  check that does not exist, and the cost lands on every other gate — red stops
  meaning anything. This is one notification path, not two bug fixes, and it is
  not yet ticketed as such.

## 10. Two operational notes from executing this

**A triage sweep looks like a factory storm.** Every label edit on an `agent`-labelled
issue fires a `factory-implement` run. Dispositioning seven `needs-triage` issues
produced roughly fifteen runs that all skipped within seconds. They skip before
claiming, so they do not appear to consume the daily budget — but anyone reading
run history as a health signal will see a burst and reasonably suspect a runaway.
If this misleads someone a second time it is worth a workflow-trigger filter;
until then it is worth knowing rather than fixing.

**Releases are capped at 6 implementation runs per day, and the cap is shared.**
#1366 and #1368 cleared the evidence-contract gate and were then deferred with
*"10 implementation runs have started today, above the configured daily cap of 6"* —
four slots had already gone to #1398–#1401, released by another actor minutes
earlier. So the eleven remaining contracts are a two-day drain at minimum, not one
batch, and the queue competes with every other lane for the same budget.

**A provenance gap the cap made visible.** Those four releases are attributed to
`fairchild`, and so are this session's. That is the *token* identity, not a person:
any agent session holding the owner's credentials satisfies `owner_release_event`'s
"the most recent `ready` label actor is the repository owner" check. The admission
model's core guarantee is that a human reviewed the content before release, and it
currently cannot distinguish the owner from an agent acting as him. Not a defect
found in the code — a limit of what the timeline can prove. Worth deciding whether
it matters before the factory's authority widens.

## Provenance

Sweep run 2026-08-27 against `origin/main` at `7af1e271`; figures in § 1 and § 6
re-measured 2026-08-28 against `b0c7b0cd`. GitHub reads went over `curl` with a
local token because `gh` could not dial. Nothing in this record has been executed
against the tracker.
