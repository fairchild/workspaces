# The Factory That Never Builds Itself

Date: 2026-07-17

The Agent Factory is the autonomous pipeline meant to advance this repo between my interactive sessions — triage, implement, review, verify, all running as GitHub Actions against labels and PRs. Six days ago it was a stalled v1: personas waking on schedules, coordinating through GitHub Discussions, quietly converting nothing. Today its v2 replacement drove five live scenarios end to end, merged three of its own PRs through counterpart review, and then absorbed a thirteen-issue refinement sweep the same evening. This post is the arc from redesign to working loop, including the part where it failed six runs in a row.

A note on who did what, because it matters: agents did nearly all of the work here. An orchestrator session planned, dispatched, and gated; implementation workers wrote the code; the factory's own personas — April implementing, Plat reviewing — drove the live runs. I made the calls that needed an owner: what to build, what to merge, when a guard was right to refuse. I steered; the system worked.

## Why v2

The postmortem that opened the arc (July 12) was unambiguous: v1 failed at conversion, not execution. The execution machinery was genuinely good — 141 agent-lane PRs merged in 60 days at an 18-minute median. But every conversion gate fanned into me on a surface I had stopped visiting. Idea-to-plan required an exact keyword comment in a Discussion; the triage persona's last successful run was April 11, and its one genuine trigger after that failed silently. Plan-to-execute required a 👍 on a specific comment. Discussions went fully silent June 9. The implement/review pair had 106 reviews between them and two implementations — reviewing was event-fired by PRs and worked; implementing required winning a scheduler lottery and didn't. And the ops dashboard froze on March 12 because the reporter ran with a read-only token and no commit step: it computed a weekly report and threw it away.

Model capability was at most secondary. The architecture made proposing cheap and finishing impossible; better models in the same pipeline would have stalled identically.

So the v2 bet, written down in [the plan](../docs/development/agent-factory-v2-plan.md) before any code: labels and PRs are the *only* control plane — a gate is a label flip, a PR review, or a merge, never a comment keyword. Six event-fired stages; an idle factory does nothing. Implement and review are counterpart pairs, so author-never-approves falls out of the routing. Evidence is a merge gate, not a courtesy. And one invariant I haven't seen in the industry framing: the factory never builds itself — its own code ships only through owner-merged PRs, at every autonomy level, forever.

## Eyes and a broom, then hands

M1 (July 13) gave the factory eyes and a broom before hands, because v1's deepest failure was that nobody could see it failing. The Monitor got a working write path — dashboard commits on a telemetry branch, so observability is durable instead of computed-and-discarded. The Digest taught the first live lesson: the plan said pinned Discussion, but the built-in Actions token can create discussions and not update them, so updates were riding an owner PAT — wrong attribution and standing credential debt. The Digest became a pinned issue maintained entirely with the built-in token, and the PAT was revoked ([#1075](https://github.com/fairchild/workspaces/issues/1075)). The janitor reconciles expected-vs-actual label state daily — event-driven pipelines stall invisibly when a trigger misfires, which is exactly how v1's triage died — with one total rule: it only ever removes lifecycle labels; applying `ready` is mine alone. The broom half closed all 25 v1 discussions and deleted the cron wake-ups.

M3 (July 15) was the hands: a four-PR stack ([#1096](https://github.com/fairchild/workspaces/pull/1096)–[#1099](https://github.com/fairchild/workspaces/pull/1099), about 3,000 lines) wiring `ready` → claim → isolated scratch implementation → evidence-bound PR → automatic counterpart review. The directed security review earned its cost: it found two blockers — a re-fire lane through which a non-owner label event could reach execution, and privileged-path guard holes (release paths missing, title-only scanning) — and both were closed in two hardening passes before merge. The claim step is now an authenticated chokepoint that verifies the latest `ready` timeline actor is the owner, release-sensitive paths come from one shared policy module, and the unsafe re-fire lane is gone.

The merge train taught its own lesson: [#1098](https://github.com/fairchild/workspaces/pull/1098) shows "merged" with a zero-line diff because a push error pointed its head branch at main's commit, which GitHub read as merged — and then auto-deleted the branch. Auto-delete-head-branches and stacked PRs are a hostile combination. The content re-landed intact as [#1101](https://github.com/fairchild/workspaces/pull/1101).

## Six runs, each failing deeper

Then we turned it on, and it failed six times in a row — and this was the good part. Every failure was strictly deeper than the last, and every one was a real bug fixed in the same session: GitHub App tokens can't assign an agent to an issue ([#1104](https://github.com/fairchild/workspaces/pull/1104)); the headless CLI refused an untrusted workspace ([#1105](https://github.com/fairchild/workspaces/pull/1105)); a checked command swallowed its stdout on failure, so the failure after that one was undiagnosable until we echoed it ([#1106](https://github.com/fairchild/workspaces/pull/1106)); the isolation flag added during security hardening turned out to conflict with OAuth auth mode ([#1107](https://github.com/fairchild/workspaces/pull/1107)); and macOS hands out symlinked temp dirs that broke scratch handling ([#1108](https://github.com/fairchild/workspaces/pull/1108)).

None of these bugs exist in a demo. All of them exist in a system. If the demo is 20% of the work and the system is 100%, this day was the other 80% arriving on schedule — progress measured entirely in how much further each run got before dying.

## The blocker that explains headless agents

July 17, morning: the first run to clear every infra fix and the evidence gate. Claim succeeded. The model ran, read the issue, chose the right action, produced a valid PR envelope — and edited zero files. The guard correctly refused to open an empty PR.

My first hypothesis was a prompt problem: the model treating the run as "describe the change" rather than "make it." The real mechanism, proven before any prompt surgery: in claude-code, `--tools` only *exposes* tools, while `--allowedTools` *permits* them — and a headless `--print` run has nobody to answer permission prompts, so every Edit was silently denied. The stream-json output carries the receipts: two `permission_denials` entries for Edit. The model attempted the right edit, was refused, and finished politely with prose. [#1112](https://github.com/fairchild/workspaces/pull/1112) pre-approves exactly the tools it exposes, and nothing more.

The quieter half of that PR is the observability lesson: output was swallowed on exactly this path, because the earlier stdout echo fired only on nonzero exit and this path exits 0. Two guesses in, we instrumented instead of guessing a third time — the mechanical proof took one repro harness and settled the question in a way no amount of prompt-tuning would have.

## Dogfood day

With the blocker closed, I drove five scenarios through the live factory as the owner. S1 was the loop proof: `ready` on a docs issue → claim → implement in the isolated scratch → PR with machinery-applied labels → Plat's counterpart review → my evidence attestation → merge, issue auto-closed ([#1113](https://github.com/fairchild/workspaces/pull/1113)). S2 was bait: an issue scoped to a workflow file, which admission rejected without ever claiming — no contributor run, no PR, only a skip comment. The factory declining work is as much a pass as the factory doing work.

S3 was the real test — two genuinely useful changes, not fixtures. A path-traversal fix rejecting `.`/`..` segments in repo-name validation ([#1114](https://github.com/fairchild/workspaces/pull/1114)), and a test-flake root cause: the tamper helper flipped the last base64url char of an HMAC, which carries only four payload bits, so roughly one run in sixteen the flip was a no-op ([#1115](https://github.com/fairchild/workspaces/pull/1115)). Both went implement → counterpart review → attestation → merge, end to end. Plat's reviews were substantive, not rubber stamps — on #1114 it independently checked all three call sites of the validator for drift before approving the approach.

S4, the responder scenario, is why I predict before firing: written predictions, then the event. The live system revealed *two* responder lanes where the plan assumed one — mention-triage with a supersede invariant, plus an owner-comment contextual responder with per-comment idempotency — and two of my plan assumptions were wrong in the details (duplicates supersede rather than skip; non-owner inertness is enforced at execution, not at reply). Predict-before-fire converted both from would-be false verdicts into corrections. One portable lesson for anyone building on Actions: comment- and label-triggered workflows run the *default branch's* definition — pre-flight against main, not your checkout.

## The sweep

Live usage generates a very specific kind of backlog: papercuts you can only feel by running the thing. Thirteen refinement issues (#1116–#1128) came out of the day, and by evening twelve were resolved — eight PRs (#1129–#1134, #1136, #1137), every one reviewed by the factory's own counterpart lane while we were still building it. The highlight: a control repro proved the scratch sandbox was escapable — the write grant wasn't path-scoped, so a run could write outside its workspace, with patch-diff filtering as the only containment — and [#1134](https://github.com/fairchild/workspaces/pull/1134) sealed it with path-scoped grants and made the stream-json telemetry permanent. The sweep also found two test suites wired into no CI at all, now registered. One issue closed as a clean audit; one was deliberately deferred as the M4 opener ([#1125](https://github.com/fairchild/workspaces/issues/1125)).

## Against the essay

v1 was inspired by the cloud-software-factories framing, so v2 owes it an honest reconciliation. Aligned: the loop itself (triage → implement → review → verify), factory-as-code, and centralizing agent operations in one place. Deliberately divergent on multi-harness: at solo scale a pinned harness is a supply-chain control, not a limitation — the sweep even pinned and tool-restricted the planner lane ([#1133](https://github.com/fairchild/workspaces/pull/1133)) — so we keep the abstraction seam and skip the machinery. Divergent on build-vs-buy too: this factory is composed out of commodity CI — GitHub Actions, labels, PRs — rather than purpose-built infra, with the tradeoff that platform quirks become your bugs (App tokens that can't assign, tokens that can't update discussions, default-branch workflow semantics) in exchange for running zero servers. Ahead on the never-builds-itself invariant, which the essay's framing lacks — even the proposed self-reflection lane ([#1141](https://github.com/fairchild/workspaces/issues/1141)) is suggestion-only by construction. And honestly behind on measurement: we built the gates before the meters. Run caps meter attempts; nothing yet meters spend. The essay's efficiency metric — shipped product over token cost — names the gap precisely, and [#1138](https://github.com/fairchild/workspaces/issues/1138) files it.

Next: a revision loop so a requested change becomes a conversation the factory can finish rather than a dead end (#1125), per-run cost telemetry (#1138), an automatability signal at triage — mechanizing the judgment I applied by hand picking S3 targets (#1139), and that bounded reflection lane (#1141).

## Stats

Recovered from the issue and PR record, July 12–17:

- Arc length: `6` days, design session to live loop
- Merged PRs in the window: `42` total, `29` with `factory` in the title
- M3 implementation stack: `4` PRs, about `3,000` lines; `2` review blockers closed in `2` hardening passes before merge
- Validation: `6` consecutive failed runs → `5` infrastructure fixes (#1104–#1108) + `1` root-caused blocker fix (#1112)
- Dogfood: `5` scenarios, `5` passes; `3` factory-authored PRs merged (#1113, #1114, #1115)
- Harvest: `13` refinement issues filed, `12` resolved the same day, `8` sweep PRs totaling about `3,000` added lines
- Test suites newly wired into CI: `2`
- v1 baseline replaced: `141` agent PRs in 60 days, but `106` reviews against `2` implementations; triage's last success `2026-04-11`; ops dashboard frozen since `2026-03-12`
- Daily attempt caps: implement `6` (raised to `15` for the fire phase, restored), review `12`

The factory is small, gated, and observable, and as of tonight it has shipped real changes through its own loop. It still never builds itself — that part stays mine.
