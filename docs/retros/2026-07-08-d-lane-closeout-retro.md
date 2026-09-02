# Retro: D-lane closeout (D1 #9, D2 #10, D3 #15)

## Metadata

| Field | Value |
|---|---|
| Model | `claude-fable-5` |
| Harness / client | Claude Code CLI |
| Session ID | `fd656fa8-63e1-44ed-be0b-b6bdb1762c1e` |
| Retro written | 2026-07-08 |
| Arc span (grounded by PR merge timestamps) | 2026-07-07T10:20:33Z (PR #884 merged) → 2026-07-08T06:05:37Z (milestone #15 closed) — **not** continuous active session time; the session was compacted once mid-arc, and the owner stepped away and returned at least once |
| Session duration (active) | unknown — no reliable start/end timestamp for pre-compaction portion; the compacted summary and this transcript together cover the full arc but I cannot state elapsed wall-clock time with confidence |
| Turns | unknown |
| Tokens (session total) | unknown — one mid-session `/context` check showed 219.1k/1M (22%) at that point; final total not captured. One subagent (`chronicle-curator`) used 52,619 tokens, separately accounted |
| PRs | 17 total — 16 merged, 1 open (#961) |
| Commits | 27 across those 17 PRs |
| Unique files touched | 82 (measured via `gh pr diff --name-only` across all 17 PRs, deduplicated) |
| Issues closed | 10 — #670, #696, #666, #783, #789, #728, #548, #679, #680, #704 |
| Issues filed (new) | 3 — #889, #892, #895 (all still open) |
| Milestones closed | 3 — #9 (2026-07-07T12:38:15Z), #10 (2026-07-07T13:17:25Z), #15 (2026-07-08T06:05:37Z) |
| Subagents used | `archive-fix`, `badge-fix` (D1/D2), `diff-actions`, `snippet-cards`, `web-snapshot` (D3), `perf-lane` (perf measurement), `chronicle-curator` (this wrapup) |

Numbers above were pulled live via `gh pr view/diff` and `gh issue view` immediately before writing this retro, not recalled from memory.

## Original goal vs. actual outcome

**Stated goal** (owner, mid-arc, verbatim intent): "continue orchestrating this run" and "continue working through all the milestones till we get all D miles completed" — full autonomous completion of the desktop milestone stack (D1, D2, D3) via orchestrator-gated subagent fan-out.

**Actual outcome:** All three milestones closed. D1 and D2 closed same-day (2026-07-07); D3 closed the following session after the owner returned to the keyboard (2026-07-08). This matches the stated goal directly — there is no scope gap between what was asked and what shipped.

The interesting delta is between what the *pre-compaction summary* predicted and what actually happened. That summary described D3's remaining work — destructive stage/unstage/discard actions (#704), session-card snippets (#680), and a bounded web snapshot (#679) — as a "live-desktop-gated tail," explicitly parked pending an unlocked screen and memory headroom. In fact, once the owner said "continue," all three shipped **without the desktop ever being live for implementation**. Subagents wrote code, ran `swift build`/`swift test`/`mise run lint`, and passed CI entirely headlessly. The only genuinely desktop-gated step was final human click-through validation — and even that got explicitly waived by the owner for the highest-risk PR (#924, see below). "Live-desktop-gated" turned out to conflate two different constraints that should have been named separately from the start:

- needs a live desktop to **implement** (mostly false for this tail)
- needs a live desktop to **validate** (true, but overridable by the owner's own risk call)

## Surprises

1. **The live-desktop-gated prediction was wrong in a useful way.** Naming it explicitly here so a future orchestrator doesn't repeat the conflation: check whether "parked" work is actually blocked on implementation or only on final validation before deferring it wholesale.

2. **Two independent wait-loop wedge bugs in the same session, and fixing the first one caused a symptom of the second.** `diff-actions`'s first codex-review watcher used `until [ -n "$(jobs -p)" ]; do :; done` as its exit gate — `jobs -p` is never populated in a fresh non-interactive shell, so it busy-spun forever (visible in `ps aux` at ~40% CPU). I diagnosed this correctly and told the subagent to kill the watcher and rerun codex directly. What I did not check first: whether the watcher was actually watching a live process. It was — PID 57495 was a genuinely running `codex exec`, and killing the watcher process tree took it out as collateral. The subagent reran fresh (correctly, this time producing a stronger review — 3 blockers instead of the 1 blocker + 2 majors my own from-scratch codex pass found independently). Net effect: no lost work, but real wasted tokens and a should-have-been-avoidable false start. **Lesson: `ps aux | grep <target>` before killing anything you've diagnosed as "stale," not after.**

3. **Redundant independent review paid for itself, once, concretely.** While `diff-actions`'s codex watcher looked wedged, I ran my own from-scratch codex pass on #924's diff in parallel — unaware the subagent's rerun was also in flight. Both surfaced the same defect class (a save-then-navigate race) via different framings: mine as "a second navigation can commit a stale target," the subagent's independently-found version as "typed edits during an async save get silently dropped." When I compared the subagent's first fix against the specific scenario I'd hand-traced, the fix hadn't fully closed it — I asked for a generation-token guard; the subagent's reply (which crossed with my ask) reported it had already reached the identical design independently. Two reviewers converging on the same missing case from different angles is a real value signal for the destructive-path PR this was — but it also cost duplicated codex runs and analysis that a one-line "I'm running my own pass on this, hold yours" message would have avoided.

4. **A genuine upstream bug, root-caused rather than guessed around.** #783/#888's resume feature required discovering that libghostty silently drops `ghostty_surface_config_s.command`/`initial_input` for every surface after the app's first — found via layered temporary `NSLog` instrumentation down to the exact `ghostty_surface_new` call boundary, reproduced on both cached and freshly-rebuilt GhosttyKit, filed upstream-adjacent as #889. This is the arc's clearest example of the repo's own stated lesson ("ship a diagnostic probe instead of your third guess") paying off — the alternative would have been several more guess-and-check cycles against a symptom that looked like "our code is wrong" but wasn't. *[Correction, 2026-09-02 (#1520): the probe-over-guessing lesson stands, but the attribution recorded here did not survive re-investigation. The marshalling seam is now pinned by a test proving `command`, `env_vars` and `working_directory` each reach `ghostty_surface_config_s`, and staged spawn-layer runs delivered all three; the loss point is unknown rather than upstream, and #889 stays open on the symptom.]*

5. **Promoting duplicated logic to one model surfaced a real correctness bug, not just cleaner code.** #680's Core-promotion refactor (unifying `SessionActivity` severity ranking) found that `AgentChromeProjection.severity` and `.sidebarPriority` disagreed on the `thinking` case — two independent ladders silently drifting. The refactor's justification going in was maintainability; the bug it caught was a bonus that validates the investment.

6. **The owner explicitly overrode the arc's own safety gate at the last mile.** #924 — the single riskiest PR in the arc (file deletion, destructive git operations) — went through two full codex review rounds and three independent orchestrator full-suite gate passes. When asked whether to merge only after a live click-through or merge on review strength alone, the owner chose the latter explicitly: "Skip the manual check, merge anyway." This is worth recording candidly rather than glossing over: the review process was trusted enough to substitute for hands-on validation on a destructive-write surface, which is either strong evidence the process earned that trust, or a real residual risk that hasn't been checked yet as of this writing (see Loose Ends).

## What went well

- **Verify-before-plan surveys** found #704, #680, and #679 all substantially pre-shipped or narrower than their issue titles suggested, *before* any implementation work started — this happened on all three D3 issues, not just one, and matches a pattern the repo has documented recurring across multiple planning cycles ("the tracker lags the code"). Reading the actual code before scoping delegated work is cheap and kept subagents from re-implementing things that already existed.
- **The codex-review-loop found real, severity-ranked defects on every genuinely risky PR**, not stylistic nits: #886's retention query (would have resurrected a stale crash run), #926's `withTaskGroup` timeout-drain bug (the "timeout" was silently a lie for a hung capture) plus a `MainActor.assumeIsolated` hardening and an empty-id routing bug, #930's stale-tail-under-wrong-agent-kind leak and a symlink/FIFO resolver block risk, and #924's TOCTOU delete race, stale-status misroute, and save-then-navigate race. That's at least 8 distinct, real defects closed by review across the arc.
- **Delegated merge authority plus draft-PR gating kept three D3 subagents working genuinely in parallel** (`diff-actions`, `snippet-cards`, `web-snapshot`), each progressing through its own plan → implement → codex-review → gate cycle without waiting on the others.
- **Explicit "builds clear" signaling** held concurrent `swift build` invocations back during the perf-measurement window, and the perf-lane subagent correctly *refused* to run timed launches under critical memory pressure rather than produce contaminated numbers — a good instance of a subagent reporting a blocker instead of silently proceeding through it.
- **Roadmap hygiene stayed current**, refreshed twice mid-arc (#899 at D2-close, #961 at D3-close) rather than left to drift — actively working against the same "tracker lags the code" failure mode named above, applied to this arc's own record-keeping.
- **Issue close-out ledgers carried real detail** (PR numbers, specific defects found and how they were fixed, what was deferred and why) rather than a bare "closed" — this retro was able to pull accurate specifics straight from those ledgers.

## What we'd tell our past selves

**Do differently:**
- Check `ps aux` for a live process *before* killing anything diagnosed as "stale" — the first wedge diagnosis was right, but acting on it without that check turned a clean fix into a second incident.
- Make concurrent independent review passes explicit. If the orchestrator is about to run its own codex pass on a diff a subagent is also reviewing, say so first — the redundancy paid off once here, but it isn't a strategy, it's a coincidence that happened to work.
- Split "live-desktop-gated" into its two real components (implementation-blocked vs. validation-blocked) the first time that phrase gets used, not after the fact.

**Keep doing:**
- Verify-before-plan surveys before delegating any issue that reads as "epic-sized" — three-for-three this arc.
- Fresh `codex exec` with the diff inlined directly in the prompt, not `codex exec resume --last` — the earlier PR #888 codex pass stalled ~42 minutes on a resume invocation that had lost the diff context; every review this arc that used a fresh, diff-inlined invocation completed cleanly.
- An independent full-suite test re-run on the actual merged commit as the orchestrator's own gate, even when the subagent's own report already says green. It found nothing new by itself this arc — but it's cheap insurance, and "it always passes" is exactly the condition under which a habit gets dropped right before the one time it wouldn't have.

## Next steps

- Re-run the `debug_no_activate` performance scenario on a genuinely quiet machine (swap actually drained, not just above the 15%-free abort line) — current result (1769ms vs. a 740ms budget) is flagged as likely swap-paging noise but is not disambiguated from a real regression in #886/#888's launch-path changes.
- Merge #961 (roadmap refresh reflecting D3's full closure) — open, ready, pure docs.
- Add the CHANGELOG/`product_overview.md` entry for #924's stage/unstage/discard + dirty-nav veto, deliberately excluded from PR #951 while #924 was still unmerged.
- Run the post-merge click-through of #924's destructive paths (checklist is in the PR body) — this is the validation step the owner explicitly chose to skip pre-merge; it is still unverified live as of this retro.
- Pick the next desktop-lane theme — the D-lane queue is explicitly empty in the roadmap now.
- Check in on the `#914`/`[A1]`/`[A2]` automation-lane arc, which the owner commissioned mid-session as a separate research track (screenshot-evidence capture) and which has already closed milestone `[A1]` #16 and has `[A2]` #17 active — substantial parallel progress this session didn't own or track closely.

## Loose ends needing attention

- `docs/user-guide/index.html` — the page actually linked as "User Guide" from `docs/README.md` — is stale content from the old Daytona cloud-sandbox integration, untouched since a branding-rename commit, unrelated to the current app. Flagged twice (PR #951's body, directly to the owner) but not acted on. The app currently has no real user guide beyond `docs/product_overview.md`.
- The dirty-navigation veto shipped in #924 explicitly does **not** cover repo-switch, workspace-switch, or web-source-selection navigation — those chokepoints mutate sibling selection before preview teardown, so gating them naively would strand half-applied state. This is documented as a deliberate deferral on issue #704, not a silent gap, but it is still a real, currently-reachable path where a user can lose unsaved editor edits without a prompt.
- #729 (cloud handoff) has an owner decision on record (yes, on a per-handoff opt-in basis, deferred to its own future milestone) but zero scheduling — it sits on an open, unmilestoned backlog issue and will stay there until a lane explicitly picks it up.
- #889 (libghostty command/initial_input drop), #892 (libghostty PID/fd exposure gap), and #895 (restore split-layout fidelity) are all filed, open, and unmilestoned.

## Issues to backlog

New, concrete, not-yet-filed items surfaced by this retro (beyond what's already tracked above):

1. **Encode a guard against the wait-loop-can't-exit failure class.** This is now at least the third occurrence across this arc's history (prior merge-watcher instances used `rg -v pending` on a single line and exited early; this session added `until [ -n "$(jobs -p)" ]` busy-spinning forever in a fresh shell). It's cheap to encode as a one-line rule in the `codex-review-loop` skill or a shared automation doc: never gate a background-process wait on `jobs -p` in a spawned shell; check liveness via the actual PID. Recommend filing this as a `quality`-labeled issue rather than leaving it as prose in a retro no one re-reads.
2. **Retire or rewrite `docs/user-guide/index.html`.** Currently orphaned, stale, and actively misleading (it's the one page literally titled "User Guide"). Worth a real issue rather than staying as a comment buried in a merged PR body.
3. **Schedule #729** into a milestone once the next desktop-lane theme is chosen, so an owner-decided feature doesn't silently age out of visibility on an unmilestoned issue.

I have not filed these as GitHub issues yet — flagging here per the requested retro format; will file on request or as part of the next planning pass.
