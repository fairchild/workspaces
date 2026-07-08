# Retro: the automation two-arc program (evidence capture → workspace orchestration)

| | |
|---|---|
| **Model** | Claude Sonnet 5 (`claude-sonnet-5`), orchestrator/coordinator seat |
| **Harness/client** | Claude Code CLI (terminal), workers via orca CLI + orchestration (worker terminals: codex `gpt-5.5` xhigh, pi 0.80.3 xhigh) |
| **Session ID** | `c14a8a9a-f99e-4b6f-a96a-8c47ef4754fb` |
| **Date** | 2026-07-07 → 2026-07-08 (written 2026-07-08, same day as closeout) |
| **Duration** | program span: ~12.5 h (ADR #913 merge 07-07 18:25 UTC → retro #960 merge 07-08 06:58 UTC); coordinator-session wall clock: unknown (context compacted twice) |
| **Turns / tokens** | unknown (not exposed to the session; two compactions discard exact counts) |
| **Files touched** | 9 implementation PRs: 88 file-changes, +7,372/−261 lines (per PR stats); plus closeout PRs #945 (+9/−2), #960 (+28/−2) and this doc |
| **Commits** | 11 squash merges to `main` (#933, #941–#943, #945–#947, #952, #954, #955, #960) + 1 review-response commit (`1e1d0833` on #947) |

**Scope:** ADR #913, PRD #914, milestones #16 `[A1]` and #17 `[A2]`. Grounded in the PR record and the orchestration session's own history.

Twelve and a half hours separated the ADR merge (#913, 07-07 18:25 UTC) from the final retro-encoding merge (#960, 07-08 06:58 UTC). In between: nine implementation PRs, two closeout PRs, one deliberate execution-agent race, one blank screenshot that beat every mechanical check, and one trust-model change nobody specced. This document is the narrative record; the shipped encodings (ROADMAP Learnings, `subagent-delegation` preflight section, evidence-lane content gate) are the operational ones.

## Original goals vs. actual outcomes

The grill session on 07-07 settled two arcs on one spine: `[A1]` reliable one-command screenshot evidence via a capture-only operator scope on the existing Automation API, then `[A2]` agent workspace orchestration under a "verbs = clicks" contract — every mutation verb enters the exact UI code path a user gesture takes, with CLI and App Intents as veneers over a single verb layer.

Both arcs shipped at full scope, on the planned slice boundaries, with no slice descoped:

| Slice | PR | Merged (UTC) | Size |
|---|---|---|---|
| `[A1]` capture spike memo (#915) | #933 | 07-07 23:20 | +22 |
| `[A1]` operator scope (#916) | #941 | 07-08 00:02 | +839 |
| `[A1]` window.snapshot (#917) | #942 | 07-08 00:41 | +767 |
| `[A1]` evidence lane (#918) | #943 | 07-08 02:14 | +403 |
| `[A2]` workspace.read (#919) | #946 | 07-08 03:06 | +540 |
| `[A2]` gesture-verb layer + select (#920) | #947 | 07-08 04:46 | +1376 |
| `[A2]` workspace.create + confirmation_required (#921) | #952 | 07-08 05:39 | +1653 |
| `[A2]` App Intents veneer (#922) | #954 | 07-08 06:37 | +813 |
| `[A2]` API smoke parity lane (#923) | #955 | 07-08 06:42 | +959 |

The two outcomes that matter beyond the checklist: `./scripts/evidence.sh --pr <N> --fixture <scenario>` is now the sanctioned first-choice capture path (the problem that motivated the whole program), and the verbs-=-clicks contract survived three surfaces (socket, CLI, App Intents) without a single service-layer shortcut landing. The parity report (#955, 3×3 runs) gives the owner the data for an eventual UI-lane retirement decision without making it for him.

What did *not* ship, deliberately: a repo-select verb (documented as a parity-report divergence rather than invented without review — filed #958), Shortcuts hands-on verification (#959, human lane), and the companion-app surface (post-A2 by design).

## Surprises

**Execution agents fail on harness, not model.** The owner switched execution agents mid-arc and asked for a deliberate race on #921: pi (0.80.3, xhigh thinking) vs codex (gpt-5.5, xhigh), same brief, same base commit, separate worktrees. Pi produced a structurally sound ~1,020-line implementation — closure-only verb layer, real sidebar helper, confirmation mapping, essentially the same design codex shipped — and died unverifiable because its sandbox blocked `swift`. Codex went dispatch→reviewed-PR in ~50 minutes. The pre-race worry had been *context absorption* (pi missing the issue tracker); that turned out to be the smaller gap. The lesson encoded in `subagent-delegation/SKILL.md`: preflight a new agent's ability to run the verification loop before handing it a slice, because every merge gate here is verification.

**The blank screenshot that passed everything** (`[A1]`, #918/#943). The evidence lane's own first PR evidence was a pure-white 2744×1764 PNG — file existed, dimensions sane, upload green, shellcheck clean, codex review clean. Root cause: the desktop auto-locked between the working 17:49 capture and the 18:51 re-capture, hitting exactly the composited-path limitation the #915 spike had documented. Only rendering the pixels caught it. Two permanent artifacts: the luminance-spread content gate in `scripts/lib/app-capture.sh` (real captures spread ≈255, blanks 0; the lane retries then fails loudly), and the coordinator practice of downloading and *looking at* every evidence image before merge.

**An implicit trust-model change in a "thin veneer" slice.** #954's App Intents mint an in-process operator handle with no experiment gate, and the controller is now configured before the `isEnabled` guard — so Shortcuts verbs work with the Automation API experiment off. Nothing in issue #922 specced that either way. Review judgment: the design is sound (intents are user-initiated, OS-mediated, in-process; the experiments gate the external socket) but it merged only after `docs/development/automation-api.md` said so explicitly. The generalizable rule: when review finds an implicit widening, the fix is often a disclosed rationale, not a new gate — but it is never silence.

**#955 found a latent bug in the authoritative lane it was mirroring.** The existing desktop-ui-smoke assertion compared duplicate reattach milestones via `events.index()`, which returns the first *equal* dict — wrong when milestones repeat. The parity work fixed it by comparing event positions. Building a second implementation of a contract is an effective audit of the first.

**A repo-level ruleset surprise:** #947's squash-merge was blocked on unresolved review threads even after the comments were addressed and replied to. Address → reply → *resolve* → merge is the actual sequence.

## What went well

**Facts before mechanism.** The #915 spike (own-window capture is TCC-free; the GhosttyKit surface presents via a readable IOSurfaceLayer; locked screens still fail) cost one worker-session and eliminated mechanism debate from all three following `[A1]` slices. Its locked-screen finding pre-explained the blank-evidence incident when it happened. Cheapest insurance of the program.

**One human review at the load-bearing slice.** The execution contract reserved exactly one PR for the owner's personal review: #947, where verbs-=-clicks is enforced *structurally* (the verb layer is constructed from gesture closures only — it cannot reach a service). After that, #952/#954/#955 extended the layer under delegated merge with zero contract drift. The coordinator review-seat checks that made delegation safe: verify the verb's entry point in the diff (never the PR prose), render the evidence, read effects back from live UI state rather than trusting claimed outcomes.

**Review feedback became spec text the same hour.** The owner's one note on #947 — transitory milestone tags like `[A2]` are meaningless outside the milestone's context — was encoded into every subsequent dispatch spec. Zero recurrences across #952/#954/#955 (verified by grep at each review).

**Injected specs carried the whole contract.** Each dispatch included the ADR sections, acceptance criteria, process gates (evidence, Mergeability fields, labels), fresh review feedback, and worktree bootstrap facts (GhosttyKit rsync). Codex workers needed zero context round-trips; a 5-question quiz (issue tracker? evidence gate? labels? Mergeability doc?) came back 5/5. The one context question that mattered — "can your sandbox run `swift`?" — wasn't asked, which is the preflight gap now encoded.

**Exit criteria that demonstrate themselves.** #918's rule — the PR's evidence must be produced by the lane it ships — is what surfaced the blank capture. #923's structure — prove parity, don't assert it — is what surfaced the `events.index()` bug. Both times the self-test caught what inspection missed.

## What we'd tell our past selves

**Do differently:**

- *Preflight the execution agent's harness before the first dispatch.* The pi race cost a worktree, a dispatch cycle, and ~1,000 lines of unverifiable work that a 30-second `swift build` probe would have predicted. (Encoded: `subagent-delegation/SKILL.md`.)
- *Never restart a live, human-approved worker session to add flags.* The coordinator killed pi's first session to add `--approve` moments after the owner had already approved it interactively — the correction arrived mid-restart. Losses were small (the session was minutes old) but it was pure haste; the flag was for *future* sessions. (Encoded in coordinator memory.)
- *Resolve review threads as part of addressing them,* not as a separate merge-time discovery (#947).
- *Don't arm redundant supervision windows.* Four separate 55-minute `orca orchestration check --wait` windows expired empty this session because worker messages were already being delivered through the harness notification path. Rolling waits are the fallback for when notifications *don't* arrive, not a parallel channel to run always.
- *Expect orca runtime restarts to invalidate terminal handles mid-supervision* (it happened twice across the program; task state survives, handles don't). Re-resolve handles from `orca terminal list` instead of caching them across long gaps.

**Keep the same:**

- Spike-first sequencing for anything with unknown platform facts.
- The one-human-review-at-the-contract-slice pattern; it bought owner-grade assurance at 1/5 of owner attention.
- Download-and-look evidence review, verify-in-diff claims review. Both caught real issues prose review had passed.
- Racing agents on a real slice as the comparison method — one hour of wall clock produced a sharper answer about pi vs codex than any benchmark reading would have.
- Same-day retro-encoding PRs (#945, #960) while the failures are still specific.

## Next steps

1. **#959 (human, ~2 min):** owner spot-checks the three App Intents in Shortcuts UI — the one acceptance surface no worker lane could drive headlessly.
2. **#958 (agent):** repo-select gesture verb, then remove the parity report's app-side-repo-selection divergence — the last gap before the API lane covers the full daily-driver walk.
3. **Decide the pi study artifact:** ~1,020 uncommitted lines still sit in the `a2-921-workspace-create` orca worktree. Archive as a comparison exhibit or delete; it should not linger as a phantom worktree.
4. **Worktree hygiene:** `a2-921-codex`, `a2-922-app-intents`, `a2-923-api-smoke-parity` (and earlier `[A1]` worktrees) are merged and removable.
5. **Re-run the parity lanes occasionally** (both are one command each) so the report's evidence stays current for the eventual UI-lane retirement decision.

## Loose ends needing attention

- **`codex-review-loop` is invisible to non-Claude workers.** `AGENTS.md` requires the skill for substantive PRs, but it lives in `.claude/skills/` — codex workers in this arc correctly disclosed "skill not available in this checkout" (#954, #955) and substituted documented self-review. Either mirror the loop's instructions into an agent-neutral home (`.agents/skills/`, where `retro` and `subagent-delegation` already live) or amend `AGENTS.md` to bless the self-review fallback for non-Claude agents. Filed as #963.
- **#934 (open):** the session-cookie tamper-test flake (~1/16 runs — last-char flip only touches base64url padding bits) has a known one-line fix and burned two CI reruns during `[A1]`. Cheap to close; still costing reruns until someone does.
- **#944 (open):** CGWindowList→ScreenCaptureKit migration, with its explicit trigger recorded. No action until the trigger fires; listed so it isn't forgotten.
- **Locked-screen capture still fails** by platform limitation. The content gate makes it loud instead of silent, and VM lanes remain the fallback — but any future "evidence lane flaked overnight" report should check screen-lock state first.
- **surface_focused remains best-effort** in no-activation runs (0–4 focus timeouts per run in the parity data, non-deterministic across UI-lane runs). Accepted policy, restated here so nobody re-litigates it as a parity failure.

## Issues to backlog

Filed during closeout, each in its lane:

- **#958** — repo-select gesture verb (agent; unblocks full API-driven daily-driver walk)
- **#959** — Shortcuts UI hands-on spot check for the workspace App Intents (human)
- **#963** — make the pre-PR review-loop requirement executable by non-Claude workers (agent; from this retro)

Pre-existing and still open, tracked with triggers rather than urgency: **#944** (SCK migration), **#934** (cookie-tamper flake — has a one-line fix waiting).
