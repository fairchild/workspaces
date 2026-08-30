# Factory lane conventions: a position

Written 2026-08-30 as the output of the first session on #1445 (a fable-session
over the workflow YAML, the factory scripts, and the factory docs). Status:
**a position to pressure-test, not a decision** — the follow-up grilling
session (#1445 § Method) decides what, if anything, becomes an ADR.

Staleness test: this doc counts 8 `factory-*.yml` workflows (1,525 lines) and
12 `scripts/factory-*.py` files (8,607 lines). If
`ls .github/workflows/factory-*.yml | wc -l` or
`wc -l scripts/factory-*.py | tail -1` disagree, the measurements here are
stale; re-verify before arguing from them.

"Lane" in this doc means what `docs/development/factory-current-state.md`'s
lane table means: one workflow file's slice of the factory pipeline. The word
carries at least three other meanings in this repo (pipeline Stage in
`docs/agents/CONTEXT.md`, the `agent`/`human` ownership axis in
`docs/agents/triage-labels.md`, milestone workstream in
`docs/agents/issue-tracker.md`) — a collision the grilling session should
resolve in the glossary.

## The verdict, first

The lane decomposition is right and should stay. The inconsistency the issue
describes is real, is smaller than the footprint numbers suggest, and is
concentrated in four places: what a decline is, who notices stranded work,
where policy values live, and which definitions must agree. Each of those
already has a best-in-class answer *somewhere inside the factory* — the
factory invented its own conventions under pressure and then didn't propagate
them. The work is propagation, not redesign: adopt a four-rule lane contract,
enforce the checkable parts in the existing CI test surface, and make a short
list of targeted fixes. No lane merges, no orchestration layer, no rewrite.

One thing outranks all of it in sequence: the issue's own urgency trigger
(owner turns per merged factory PR, once the revision loop runs) is currently
unmeasurable, because the revision loop has never run — see the first specimen
below.

## The measurements, redone

The issue's numbers were right when written and have already drifted — itself
evidence about how fast this surface moves.

| Claim in #1445 | Verified 2026-08-30 | How to check |
|---|---|---|
| 7 factory workflows | 8 (`factory-revise.yml` merged since) | `ls .github/workflows/factory-*.yml` |
| 1,174 lines of workflow YAML | 1,525 (29.7% of the repo's 5,127 workflow-YAML lines; 38% counting `_evidence.yml`, which two factory lanes call) | `wc -l .github/workflows/factory-*.yml` |
| 7,496 lines of Python across 9 scripts | 8,607 across 12 `factory-*.py` files; workflows actually invoke 11 scripts totaling 8,349 (10 factory-named plus the Monitor's `ops-report.py` at 1,364; `factory-dashboard.py` and `factory-worker-token.py` are laptop/operator-only) | `wc -l scripts/factory-*.py` |
| 21 `FACTORY_*` variables | 38 distinct names in scripts + workflow YAML. The steward's 32 is exact under "names that touch a process environment or repo variable." The issue's 21 undercounts because its taxonomy (enable flags / caps / expectation-passing) has no bucket for 11 of the names: there are 7 enable flags (not 6), 5 cap variables (not 3 — the two runaway caps), and a credential/actor/telemetry group that fits none of the three buckets | `grep -rhoE 'FACTORY_[A-Z_]+' scripts/*.py .github/workflows/*.yml \| sort -u` |

The full classification: 12 GitHub repo variables (7 enable flags, 5 caps),
18 env names one workflow sets for a later step or the contributor runtime,
8 internal Python constants that merely wear the prefix. Only the 7 enable
flags are tracked in `config/github/repo-variables.json` — **the 5 cap
variables are not in the manifest, so `repo-variables-drift.yml` never checks
them.**

## New specimens from this session

The issue's five specimens (three in the body, two in the steward comment)
all reproduced. Working the exploration added three more, same disease.

**6. The revision loop has never run, and nothing noticed.** Every Factory
Revise run in the lane's existence — six: two on 2026-08-29 (reviews on the
PR that introduced it), four on the morning of 2026-08-30 — ended in
`startup_failure`: zero jobs, so no kill-switch check, no comment, no
escalation. Diagnosis (inferred from the caller diff; GitHub
doesn't expose startup-error text via API): `factory-revise.yml` sets a
`contents: read` permission floor and its `evidence` job calls the reusable
`_evidence.yml` with no job-level grant, while the callee declares
`issues: write` and `pull-requests: write`; a called workflow requesting
permissions its caller doesn't hold fails the entire run at startup.
`factory-implement.yml`, the working caller, grants those permissions at the
workflow level. Filed as #1446. Separately, `FACTORY_REVISE_ENABLED` is
`false`, so even a startup-fixed lane runs dark. The lane whose design doc
promises "a review this lane touches never ends in silence"
(`scripts/factory-revise.py:6-21`) cannot start, and no surface the Owner
reads says so — the Digest's actionable sections derive from label and PR
state, and its one run-derived input (ops-report's aggregate failure-rate
breach) has no per-lane resolution for six startup failures to register in.

**7. The silence guarantee has a hole exactly at kill-switch time.**
`factory-revise.py` checks its enable flag before dispatching *any*
subcommand (`main`, scripts/factory-revise.py:904-917) — including `resolve`,
the job that exists to speak when everything else declined. Flip
`FACTORY_REVISE_ENABLED` off between the review event and the resolve job and
resolve exits 1 having posted nothing, while Review Response already deferred
on the same event and posted nothing either. Verified in code, not observed
live.

**8. The operational reference drifts in days, not months.**
`docs/development/factory-current-state.md` § "Dispatch mechanism (in flight)"
says the ready-queue sweep is "Not merged as of this writing" — it merged
(#1172) and runs daily from `factory-monitor.yml:218`. The switch inventory
says `FACTORY_REVISE_ENABLED` is unset — it is set to `false`. `FACTORY_WIP_CAP`
(the concurrent-claims cap, hardcoded 2 at `scripts/factory-implement.py:47`)
appears nowhere in the switch inventory. The header still says "as of
2026-08-04" over sections edited 2026-08-28. This is not carelessness — the
doc's own header predicts it ("it will drift otherwise"). A hand-maintained
prose registry cannot keep up with this repo's merge rate; the machinery
registries (`config/github/repo-variables.json` + its drift workflow +
`scripts/tests/test_factory_workflows.py`) are the ones that have stayed true.

## The five questions

### 1. What should a lane do when it declines?

The lanes already share three-quarters of a convention. Every script returns
0 for a *decision* and reserves non-zero for *errors* — with three places
that classify a policy outcome as an error. The review executor's
daily/runaway caps raise and go red (`scripts/factory-review.py:388-408`).
The implement lane's `authorize` re-checks the same budget its `claim` step
had treated as a comment-and-exit-0 decision, and raises
(`scripts/factory-implement.py:877-881`). And implement's
`verify_release_actor` (`scripts/factory-implement.py:700-707`) turns "this
issue's `ready` wasn't released by the owner" — reachable from the lane's own
owner `workflow_dispatch` — into a red run that comments nothing and, because
the issue-number output is written only later, skips the rollback job too;
the sweep treats the identical condition as a filter and moves on
(`scripts/factory-sweep.py:148-150`). The issue's specimen 1 is not "two
lanes disagree"; it is "the factory has a rule and a few spots break it" —
one of them intra-script, one of them red and silent at once.

Decline *visibility* is where real divergence lives. Four shapes today, plus
red: speak-and-relabel (implement's two terminal declines,
`scripts/factory-implement.py:826-829`; revise's post-defer escalations,
`scripts/factory-revise.py:496-502`), speak-only (implement's stale-scope and
wip/budget deferrals, `:830-849`), label-only (review response mutates
`owner-action` on skip decisions before returning, commenting nothing —
`scripts/factory-review-response.py:804-824`), and fully silent green
(implement's three label-state skips, `:850-851`; the review executor's nine
decline reasons, no comment, no label; evidence verify, which returns without
commenting or labelling on every precondition failure; the comment
responder's five stand-downs). A single lane — implement — spans three of the
four. No factory workflow writes a `GITHUB_STEP_SUMMARY`, so a green run that
declined nine ways is indistinguishable from a green run that worked, without
opening logs.

The best-designed decline path in the factory is the newest: the revise
lane's rule that every decline downstream of Review Response's defer carries
`escalate=true`, because the defer means nobody else will speak for this
event. That generalizes into the contract rule: **a lane may stay silent on a
decline only when the work is not standing (nothing to retry) or another
mover provably picks it up; red is reserved for "the factory itself is
broken."** Under that rule the review-cap red runs become decisions, the six
red runs that meant "working as designed" stop happening, and rule-of-thumb
triage of the Actions list becomes possible: red = fix the factory.

### 2. How does a declined thing get retried — and whose job is it to notice?

The factory already answered this for one lane and not the others. The
Monitor's daily sweep (`scripts/factory-sweep.py`) re-derives the standing
`ready` queue from label state and re-dispatches the implement lane within
remaining cap headroom — level-triggered recovery, the correct shape, and the
issue's specimen 3 ("caps reset but nothing re-fires") is already fixed *for
implement only*. Nothing equivalent exists for review. Two lanes can re-fire
it, both only on a narrow success transition and neither derived from
standing state: Evidence Verify dispatches when evidence completes while a
rejection still stands (`scripts/factory-evidence-verify.py:455-460`), and
revise's resolve dispatches after a body-only turn that clears the readiness
gate (`scripts/factory-revise.py:757-790`). A PR that was cap-declined, or
whose review run never fired, matches neither and waits for a push that may
never come — the steward's five-frozen-PRs specimen, structurally.

The digest's "Needs your merge" section keys off the linked issue's
`mergeable` label, not off whether any review exists at the current head
(`scripts/factory-digest.py:578-599`), so a never-reviewed PR and a
reviewed-but-not-yet-mergeable one both render as `review`,
indistinguishably. And the exit-code inconsistency corrupts the factory's own
telemetry: ops-report's CI summary reads every completed run with no workflow
filter (`scripts/ops-report.py:734-790`), so a review-cap red run raises the
failure rate behind the `ci` breach while an implement cap decline enters the
same denominator as a success and dilutes it.

Position: **the Monitor is the noticer, singular.** The convention worth
writing: every lane's standing work must be derivable from GitHub state
(labels, PR state, review state), and the Monitor's daily pass must derive
it. Lanes stay event-fired; the Monitor closes the gaps between events. The
one genuinely new mechanism this position proposes is the review-side
counterpart of the sweep: derive open, non-draft, single-`author:`-labeled
PRs with no counterpart review at the current head, and dispatch
`factory-review.yml` for the oldest within cap headroom. That is more Python
on the pile the issue already finds heavy — the cost is real — but it is the
piece that converts three of the eight specimens (2, 3, 4) from recurring
diagnosis rounds into a daily self-heal, and it replaces the human job of
noticing frozen PRs, which is currently nobody's.

### 3. Where is the single description of the caps, flags, and lane ownership?

Today: `factory-current-state.md`'s switch inventory and lane table — prose,
hand-maintained, demonstrably stale within days (specimen 8), and incomplete
(no `FACTORY_WIP_CAP`, no sweep row, no runaway caps at first writing). The
repo's own history says which registry style works: the enable flags stopped
shipping dark the day they entered `config/github/repo-variables.json` with a
CI drift gate behind them (#1149 → `repo-variables-drift.yml`).

Position: promote the manifest to *the* registry. Add the five cap variables
to `config/github/repo-variables.json`; extend each entry with the fields a
reader actually asks for (kind: flag/cap; owning lane; default; what exhausts
or flips it); have `scripts/tests/test_factory_workflows.py` assert that
every `FACTORY_*` repo variable a workflow or script reads appears in the
manifest and vice versa. Then cut the switch-inventory table from
`factory-current-state.md` down to a pointer. Prose explains; the manifest
enumerates; CI keeps the enumeration honest. Encode-at-the-cheapest-surface
is already this repo's stated doctrine (root `AGENTS.md` § Startup Instruction
Budget) — this applies it to the factory's own operating manual.

### 4. Are eight lanes the right decomposition?

Yes, with more confidence than the issue expected. The decomposition mirrors
GitHub's event model plus the trust boundaries: one lane per event kind, with
signal/execute splits exactly where an untrusted event must not reach a
credentialed runner (review → review-execute), and the one shared-event seam
(review-response and revise both fire on `pull_request_review`) is precisely
where the factory spent its most careful design — the defer protocol, the
markers, the attestations. Merging lanes would erase trust boundaries;
splitting further has no event to split on. Seven-lanes-as-accretion is the
wrong diagnosis.

What accreted is *reimplementation inside the lanes*. Each lane re-solves
admission, caps, actor trust, voice, and telemetry. The scripts already
invented the cure — `importlib` sibling-loading with "must stay
single-sourced" comments (`factory-sweep.py:46-62`,
`factory-review-response.py:48-73`, `factory-revise.py:48-73`,
`factory-review.py:31-35`) — and applied
it wherever a script writes or dispatches. The read-only reporting scripts
never got it — `factory-digest.py` and `factory-janitor.py` import nothing
but the standard library. Hence the duplication ledger: `is_factory_implement_dispatch` defined in both
`factory-implement.py:533` and `factory-digest.py:227` **and already
divergent** (implement's skips the actor filter when the owner env is empty;
digest's always filters — the budget can disagree with itself today, not
hypothetically); the daily-cap parser four times (`factory-implement.py:520`,
`factory-review.py:275`, `factory-revise.py:200`, `factory-digest.py:250` —
the sweep is the only reuser); the cap default `6` in six
places across Python and YAML; two different sets both named
`FACTORY_LABEL_ACTORS`; four independent ways to learn who the owner is;
three independent readers of the claim-marker grammar. Position: consolidate
the must-agree definitions (a shared module or systematic sibling-loading —
whichever the grilling prefers; the mechanism exists either way), and treat
"a policy value defined twice" the way the repo treats an unset enable flag:
a CI failure, not a code-review hope.

### 5. Does the identity model need to change before the factory's authority widens?

It already needed to and the change is already built — what's missing is
activation, which is Owner work, not design work. The `workspaces-factory`
App shipped (#1180) with manifest, token minting, worktree-scoped identity
script, and a written proof-PR checklist; no `FACTORY_WORKER_APP_ID` exists
in the repo's variables, so every CLI worker session still authors as
`fairchild`, no owner-credentialed session can formally approve those PRs
(GitHub blocks author-as-approver), and the
§ 10 provenance gap (an owner-credentialed agent's `ready` flip is
indistinguishable from the Owner's) stands exactly as
`docs/product/2026-08-27-backlog-condensation.md` recorded it. Two facts
sharpen the urgency since that write-up: the revision loop *is* an authority
widening (April pushing to her own PR branches on a review event) and it
merged; and `config/github/rulesets/main-merge.json` has required one
approving review since #1213 (2026-08-05) — `factory-current-state.md`'s
pre-flight audit still records the old `0`, another instance of specimen 8 —
so the requirement already exists and the missing piece is exactly an
identity that can satisfy it on worker-authored PRs. The identity question is
therefore one Owner action, not an exploration: install the App (two clicks,
checklist in `factory-current-state.md` § "Michael's two clicks") and run the
proof PR. It doesn't belong inside a lane-conventions refactor; it should
precede the next widening.

## The lane contract (proposed, four rules)

1. **Red means the factory is broken.** Non-zero exits are for malformed
   input, missing credentials, switches flipped mid-run, internal errors.
   Every policy outcome — cap exhausted, wrong state, nothing to do — exits 0.
2. **A decline that leaves work standing must be derivable by the Monitor.**
   Standing work lives in GitHub state; the Monitor's daily pass re-derives
   and re-dispatches within cap headroom. Comments on decline are courtesy to
   the human reading the thread, never the recovery mechanism.
3. **Silence needs a designated voice.** A lane may post nothing on decline
   only when the work is not standing or another lane provably speaks for the
   same event — and that guarantee must survive kill-switch flips.
4. **One definition per policy.** Every cap, marker grammar, actor set, and
   owner-identity source is defined once and imported; every repo-variable
   policy lives in the manifest the drift gate checks. Two definitions of one
   rule is a CI failure.

## What this costs, and what it does not propose

The contract's enforceable parts land in `scripts/tests/test_factory_workflows.py`
and the manifest — machinery, which is what has stayed true here. The prose
part is one short section, not a new document to drift. The review-side sweep
is the only net-new mechanism (~150–300 lines of Python plus a Monitor step);
it grows the footprint the issue is uneasy about, and that is the tradeoff to
grill hardest. The consolidation pass shrinks effective surface without
shrinking line counts much. Explicitly not proposed: merging or splitting
lanes, a workflow generator or DSL, any queue or state service outside
GitHub, rewriting the scripts as one application, new personas or
credentials beyond activating the already-built App.

## Sequencing

1. Fix #1446 (one permissions stanza; owner-credentialed session — workflow
   files are behind the human gate) and decide whether to arm
   `FACTORY_REVISE_ENABLED`.
2. Let the revision loop actually run; only then does the issue's [F2]
   trigger — owner turns per merged factory PR — mean anything.
3. Grill this position (`grill-with-docs`), resolving at minimum: the four
   contract rules, the review-sweep tradeoff, the "lane" glossary collision,
   and the worker-App activation.
4. Whatever survives becomes an ADR plus a fix list; the specimens in #1445
   become its regression examples.
