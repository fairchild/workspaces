# Agent Factory

The development-process context: the language of the autonomous loop that advances this repo between the Owner's interactive sessions. Distinct from the product domain in the root `CONTEXT.md`.

## Language

**Factory**:
The autonomous development system — agents plus the GitHub state machine they run on — that advances the repo between the Owner's interactive sessions.
_Avoid_: automation, agent team (the personas, not the system), pipeline (a Factory has one)

**Owner**:
The single human authority the Factory gates on.
_Avoid_: user (product-context term), maintainer (a broader GitHub permission class)

**Gate**:
A point where the Factory waits on the Owner, expressed as exactly one of: a label flip, a PR review, or a merge.
_Avoid_: approval keyword, reaction gate, sign-off

**Interactive Lane**:
Development done live in the Owner's own working sessions, outside the Factory.
_Avoid_: fast lane, manual work

**Inlet**:
A source of inbound Factory work: product feedback, Owner steering, or signals the Factory raises itself.
_Avoid_: queue, backlog source

**Steering**:
Owner-originated intent entering the Factory asynchronously through an Inlet, rather than through a live session.
_Avoid_: command, request, directive

**Digest**:
The single rolling surface where the Factory presents its open Gates to the Owner, each answerable in one gesture.
_Avoid_: dashboard (the committed telemetry artifact behind it), notification feed

**Stage**:
One event-fired step of the Factory's pipeline: Triage, Spec, Implement, Review, Verify, or Monitor. **Triage and Spec are aspirational** — designed in the v2 plan (M2) but no workflow currently fires either; Implement, Review, Verify, and Monitor are live. See `docs/development/factory-current-state.md` for what's actually wired.
_Avoid_: phase (roadmap term), agent (an identity may run several stages)

**Spec**:
The reviewable pair of artifacts — product behavior invariants plus technical plan — that a spec-only PR carries; merging that PR is the Gate that releases implementation.
_Avoid_: plan, design doc, RFC

**Monitor**:
The Stage that observes the Factory itself: writes the Digest and dashboard, ages and escalates Gates, reconciles expected-vs-actual state, and raises issues from CI signals.
_Avoid_: observer (retired persona framing), ops report

**Persona**:
A named, role-bound Factory identity — a GitHub App credential, a perspective lens, an `author:` label, and a long-term memory — that acts only when an event routes work to it.
_Avoid_: bot, scheduled agent, character

**Memory Block**:
One fact a Persona keeps: a markdown file with YAML frontmatter (short slug name, freshness metadata) in that Persona's own memory directory.
_Avoid_: note, log entry (that's the Journal)

**Journal**:
A Persona's append-only observation stream, written directly after non-PR work; raw material for consolidation, never consumed as instructions.
_Avoid_: memory (unconsolidated), diary

**Profile**:
A Persona's short machine-readable self-description — strengths, known areas, calibration — that Triage reads when routing implementer vs reviewer.
_Avoid_: persona prompt (the lens), bio

**Dreaming**:
A periodic or triggered consolidation pass in which a Persona curates its Memory Blocks from its Journal and history — compacting, refreshing, and retiring stale blocks.
_Avoid_: garbage collection, compaction (mechanical framings)

## Relationships

- The **Factory** advances work only through state transitions on issues, labels, and PRs; comment keywords and reactions are never control signals.
- Every human decision in the **Factory** is a **Gate**; anything else runs without the **Owner**.
- The **Factory** and the **Interactive Lane** ship into the same repo and the same label state machine.
- The **Owner** steers the **Factory** through the same **Inlet** as product feedback; **Steering** and feedback differ in trust level, not in path.
- The **Digest** renders open **Gates**; a committed telemetry artifact backs it.
- A **Persona** writes its own **Memory Blocks** and **Profile** only inside reviewed PRs; the counterpart Persona reviews every self-modification. The **Journal** is the only direct-write memory surface, and it is append-only.
- **Dreaming** consolidates **Journal** entries into **Memory Blocks**; consolidation lands through the same reviewed-PR path.

## Example dialogue

> **Dev:** "The planner used to wait for the Owner to reply 'plan it' on a thread — is that a **Gate**?"
> **Domain expert:** "No. A **Gate** is only a label flip, a PR review, or a merge. Keyword parsing is the failure mode Gates replaced."

## Flagged ambiguities

- "Gate" vs the "gate label" category in `docs/agents/triage-labels.md`: a **Gate** is the human decision point; gate labels (`safe-to-run-agent`, `needs-human`, `privileged-agent-patch`) are one mechanism that implements certain Gates.
- "Agent team" named the personas (April, Plat, Peter, Oliver); **Factory** names the whole system. Resolved: Personas survive as role-bound identities — April and Plat as the implement/review pair (each reviews the other's work), Peter as triage and spec author, Oliver as the deterministic Monitor's name. No Persona is ever scheduled to "find something to do." Peter's role is parked, not live: `run-planner.py` is hardened and tested, but no workflow trigger invokes it (see `docs/development/factory-current-state.md`).
- "Heartbeat" is resolved: the Monitor's daily pulse is the Factory's only heartbeat; work moves by label events, and an idle Factory does nothing. Avoid using "heartbeat" to mean scheduled contributor wake-ups — that model is retired.
