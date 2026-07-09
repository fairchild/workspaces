# W6 retro — host compute + daily-driver depth

- Arc: milestone [W6](https://github.com/fairchild/workspaces/milestone/19), 2026-07-08 → 2026-07-09, single coordinator session (Conductor `amman-v3`, session `b5933045-65bc-42fa-befd-67b77590b5db`)
- Founding decision: `web-next/docs/decisions/host-compute-daily-driver.md` (PR #988, closed #972)
- Contract: Fable coordinates, reviews, and merges on green; codex CLI (gpt-5.5) implements; a directed codex review runs on every task — the owner's explicit extension of the W5 contract, and the arc's most consequential choice.

## What shipped

Nine issues, nine PRs, one day: #986 session-list workspace (#1002), #809 mobile
polish (#1010), **#981 host compute provider** (#1012 — the keystone: turns via
the local `claude` binary, subscription-billed by construction, hard read-only
v1), #982 approval protocol (#1016), #983 local serving mode (#1017), #984
mid-turn steering (#1018), #985 config parity (#1019), #820 PR-from-session
(#1021), plus infra: setup env-linking (#1013), worker-report cleanup (#1011),
and the review-loop learnings encoded into the skills (#1020).

web-next now runs as a daily driver in two shapes: standalone (searchable
sessions, steering queue, approvals, PR-out) and owner-local
(`pnpm start:local`, loopback + minted token, host compute on the owner's
subscription). The first validated host conversation — two real turns through
the local binary with session continuity — is evidence on #1012.

## The number that matters

**15+ substantive defects caught pre-merge, ~7 of them blockers that green
gates would have shipped** — billing silently flipping to API keys, user
settings re-granting write tools past the allowlist, tap-stealing hit areas,
double-dispatch races, a stranded-claim crash window, installation-wide
tokens, a safety-net push quietly traded away. Every layer of the loop caught
something every other layer missed, including CI's perf floor catching a 2x
LCP regression both reviewers read straight past. The full analysis and the
resulting skill changes live in `.claude/skills/codex-execution/README.md`
(human-facing) and the two updated SKILL.md files; the reusable question
taxonomy is `.claude/skills/codex-review-loop/references/attack-patterns.md`.

## Surprises

- **Directed codex reviews of codex implementations worked on every task** —
  the prior skill guidance said skip them. Independence came from fresh
  context and adversarial framing, not model identity. (Falsified guidance
  deleted in #1020.)
- **Reaction commits were a real defect source** (mine included: a
  test-point inside a corner radius, a template-literal escape bug, `git
  add -A` shipping a worker report to main). Review-after-reactions is now
  the standard order.
- **The owner testing live was a finding generator**: the broken local
  sign-in exposed both a setup-script gap (#1013) and the fact that local
  OAuth never existed; the repo-picker fixture question exposed the
  auth/directory coupling — all folded into #983's design before its
  implementation dispatched.
- **Codex quota is an arc-level resource.** One usage-limit wall stalled the
  keystone ~2.5h; a sleep-queued redispatch died silently with a session
  restart. Quota handling is now in the skill.

## Loose ends (deliberate)

- **#987 native embedding** — the one milestone issue left open; desktop-lane
  Swift work outside this arc's web-next containment. Needs an owner lane
  decision (dispatch shape, evidence lane) before claiming.
- **Gap wave**: #998 (host working-copy lifecycle), #1004 (harness server
  leak), #1014 (provider-aware preflight + host validation stage — also the
  home of #820's live-flow validation debt). Proposed as the next small wave.
- **Perf floor headroom**: `route_home` LCP budget (120ms) sits at the CI
  noise floor; data on #856. Expect coin-flip failures until Gap A lands.
- **Host approval integration**: #982's `TurnRequest.requestApproval` seam is
  ready; wiring the host provider to it unlocks write tools behind Allow/Deny
  — the natural W7 headline.

## Advice to the next arc

Write the attack-surface map before dispatching the review — the loop's
quality ceiling is set at question-writing time. Tier review effort by blast
radius, not diff size. Treat the owner's live testing as a first-class
review layer and fold its findings into not-yet-dispatched briefs. And read
`attack-patterns.md` before reviewing anything that spawns processes.
