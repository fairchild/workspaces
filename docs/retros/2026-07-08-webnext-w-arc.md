# Retro: the web-next W arc (2026-07-07 → 2026-07-08)

A reflection on the four-milestone arc that took web-next from a mock-only
skeleton to a shipped product at folio.cloudcompute.com. Written by the
orchestrating agent at arc close; the shipped-encoding companion to this
narrative is PR #953 (roadmap sync, deploy/validation doc lessons, the
`codex-execution` skill).

## What we set out to do

At the start, web-next was a settled design rendered from a mock: Folio UI,
durable turns, auth — and no real agent had ever run. The contract was to
drive milestones [W1]#11 → [W2]#14 → [W3]#13 → [W4]#12 to completion in
phased critical-path order: make the runtime real and the session a usable
object (titles, model selection, a real repo picker), prove it against the
deployed app with a repeatable validation harness, polish what serves a
single-user tool, and make it primary. Quality and performance over
throughput; delegated merge authority behind evidence gates; no deadline;
subagents implement, the orchestrator gates and merges.

## How it went

All four milestones closed in roughly 36 hours of wall clock: 19 W-lane PRs
merged (18 orchestrator-gated subagent/self PRs plus one codex-authored PR),
every one through the same gate — CI green, evidence uploaded, readiness
fields exact, rebase-freshness checked. The ship itself reshaped at the gate:
the plan said "cutover," but when the moment came the owner chose no cutover
at all — the old dashboard stays in maintenance mode and web-next ships at
its own domain. Nothing was lost in that reshape; "become the primary
surface" was always the intent, and a fresh domain satisfied it with less
risk than a swap.

The end state is verifiable rather than asserted: the daily validation lane
runs the full ladder against folio — posture 7/7, authed flows 2/2, model
sweep 4/4, deployed-safe e2e 11/11, and a paid real agentic turn 9/9
(sandbox boot → streamed durable log → nonce-verified code change → clean
teardown, ~24s).

## What surprised us

**The tracker lied more than the code did.** The roadmap said web-next had no
perf budget; it had a full contract with a hard CI gate (#761). Open issues
described work that had already shipped. Every planning pass that started
from the tracker instead of the tree paid a verification tax. The lesson was
already in AGENTS.md ("the tracker lags the code") and it still cost us —
which says the lesson needs to fire at planning time, not live in a list.

**Infrastructure failure modes masqueraded as application bugs.** The
Vercel ignored-build-step silently CANCELs any deployment whose HEAD commit
doesn't touch `web-next/` — which is every env-only change. Twice we chased
what looked like an OAuth state bug (`state_mismatch`) that was actually a
stale build serving an old `BETTER_AUTH_URL`. The diagnosis tool being wrong
was the second variant: a "dead" validation session was really a malformed
curl header in my own test (the stored secret was raw, my test sent it
nameless). Both cost real time; both are now written down where the next
session will trip over them (deploy.md, the validation-identity doc).

**The OAuth confusion resolved backwards.** Sign-in used an OAuth App
(client `Ov23…`) while the owner edited the GitHub App (`Iv23…`) — the
classic two-registrations trap, visible in the client-ID prefix the whole
time. The surprise is that the "wrong" edit was the better end state: GitHub
Apps take up to ten callback URLs where OAuth Apps take one, so switching
the deployment to the GitHub App's credentials gave us folio *and* the
vercel.app origin simultaneously. The last barrier was GitHub's consent
button never enabling headless (its enable check wants window focus) —
client-side-only, so force-enable-and-submit worked, and consent is
once-per-account.

**Codex overperformed as an implementer.** Dispatched once, on a
well-specified two-flake brief: correct root causes for both races,
event-driven fixes, unprompted mutation checks, and it generalized house
style (replaced a raw `rm -f` with the sanctioned clean script) without
being told. One pass, ~208k tokens. The orchestrator review still earned its
place — it caught a stale-lock lifecycle hole codex missed — but the
implement/review split held up exactly as designed.

**Spend limits are a real operational failure mode.** Three subagent deaths
mid-flight to Claude spend caps, each needing a resume with re-grounding.
That pressure is what triggered the codex pivot, which then turned out to be
good on its own merits.

## What went well

The **authority contract negotiated up front** was the single biggest
cycle-time lever, confirming the 2026-07-02 lesson: no approval round-trips,
because "merge when green + evidenced + reviewed" was agreed before the
first PR existed. Related: **phase order by critical path, not milestone
number** meant the perf floor landed first and the ship gate last, so
nothing merged against an unguarded baseline.

**Repeatable verification beat interactive verification everywhere it was
tried.** The validation harness (skip-not-fail semantics, one secret per
stage) turned "is prod actually working?" from a browser session into a
command, and the mint script's response-tracing made every OAuth failure
legible from a log line — each failed sign-in told us exactly which
registration, origin, and redirect was involved.

**Lessons encoded at repo surfaces stuck; lessons in brief text didn't.**
The ad-hoc `rm -rf` rule failed twice as prose in subagent briefs, then
succeeded permanently as a clean script + AGENTS.md line + settings
allowlist. Same pattern at arc close: the retro shipped as diffs (docs,
skill, config sync), not as a report.

**Honest gates caught real problems late.** The rebase-freshness rule
(learned from #929's stale-base flake) forced a re-gate of the codex branch
on current main — which surfaced that a stale `.next` build was serving
pre-rebase behavior and failing the new a11y specs. "Gates green" on the
wrong build is worse than red.

## Advice to ourselves at the start

**Do differently:**

- **Start the credential chain on day one, in the background.** The #814
  identity work (machine account → session seed → bypass secret → gateway
  credits → OAuth callbacks) was the arc's long pole and the only part with
  hard owner round-trips. Every other lane could proceed autonomously; this
  one gated the finale. Sequence owner-dependent provisioning first, not at
  the phase where it's consumed.
- **Probe the deploy pipeline's env-only path before you need it.** One
  deliberate test deploy would have surfaced the ignored-build-step CANCEL
  before it could impersonate an auth bug.
- **Verify which registration serves sign-in before asking for a callback
  edit.** The client-ID prefix (Ov23 vs Iv23) answered it from the first
  trace line; we flagged the doubt but still let the edit land on the wrong
  app once.
- **Write the secret's format contract next to the secret.** `raw token,
  not name=value` is one line in a doc; not having it produced a phantom
  outage and an hour of misdiagnosis.
- **Dispatch codex earlier for well-specified diagnostic work.** We proved
  it on the last work item of the arc; it would have absorbed several
  mid-arc fix lanes at lower cost than Claude subagents under spend
  pressure.

**Do the same:**

- Negotiate the authority contract before the first PR.
- Order by critical path; land the guard rails (perf floor, validation)
  before the features they protect.
- Keep the orchestrator's hands off implementation and on gating — every
  merged PR got a genuine review pass, and two of nineteen needed
  substantive reaction commits.
- Encode every lesson the moment it costs something, at the cheapest surface
  that fires at the right time — and prefer machinery to prose.
- Run long operations in the background with watchers; the orchestrator's
  context is the scarcest resource in a multi-day arc.

## What to try next

- **#820 — PR-from-session** is the standing follow-up, deliberately
  design-first: which credential opens the PR, branch strategy, how the PR
  reads in the session UI, guardrails. Write the decision doc before cutting
  implementation issues.
- **Codex as the default implementer** for well-specified, scope-fenced work
  (the `codex-execution` skill is the contract); reserve Claude subagents
  for design-heavy or ambiguous lanes.
- **A second real user** is the trigger that un-parks #829 (owner-scoped
  sessions) and the deferred a11y items (#804/#809). Until then they stay
  parked — craft aimed at users who don't exist yet is breadth, not quality.
- **Refresh the perf baseline post-arc** — the ratchet only tightens, and the
  arc added surface area (drawer, lifecycle, multiline compose); a fresh
  dated baseline makes the next regression legible.

## Loose ends and backlog candidates

- **The old OAuth App (client `Ov23liLrhAxZ…`) is now unused** for sign-in.
  Deleting or archiving it removes the two-registrations trap permanently.
  Owner action; cheap.
- **The mint script lives in session scratchpad.** The re-seed *mechanics*
  are documented in the validation-identity doc, but the working Playwright
  script (headless sign-in, consent force-enable, trace lines) should be
  committed — probably `web-next/scripts/` with the validator credentials
  read from env — so the next rotation is a command, not an archaeology dig.
  Backlog it.
- **Watch the first unattended cron run** of `web-next-validate.yml` against
  folio with the rotated secret; tonight's greens were all driven runs.
- **"Maintenance mode" for the old `web/` dashboard is undefined.** It
  still serves webhooks and hosts the (paused) PR reviewer. Define what
  maintenance means — security patches only? dependency floor? sunset
  date? — so drift there is a decision rather than an accident. Backlog it.
- **Preview deployments run bypass auth** (the OAuth trio is deliberately
  production-only). That's the documented intent, but it's worth an explicit
  line in deploy.md's env matrix the next time someone touches preview
  behavior.
- The fable-5 reasoning-budget quirk (empty reply under a tiny
  `max_tokens`) is fixed at our probe, but it's a general trait of
  reasoning models — any future "tiny liveness call" should budget for
  thinking tokens or it will read as an outage.
