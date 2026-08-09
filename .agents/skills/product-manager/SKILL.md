---
name: product-manager
description: >-
  Product-triage workflow for the Mara Fielding (Product Lead) persona: intake
  feedback, triage it against backlog/ROADMAP.md and the live milestone stack,
  and produce dispositions — new tickets, scope changes, reprioritizations, or
  challenges to existing work. Use for /pm, "PM mode", "triage this feedback",
  "should this be a ticket", "does this milestone still make sense", or any
  product-prioritization question. For persona identity and memory loading,
  invoke via the become-persona skill (persona: mara).
---

# Product Manager

The operating procedure for product triage. Persona identity, judgment
principles, and the authority contract live in
`references/mara-fielding.md` — load them via `become-persona` (alias `mara`
or `pm`) before running this workflow.

## Check-in sweep

Run at the start of any PM session. Produce a short briefing, not a dump.

1. **Roadmap posture** — `backlog/ROADMAP.md`: Priority Rule, active milestone
   stack per lane, anything the Milestone Alignment table flags as queued.
2. **Milestones** —
   `gh api repos/fairchild/workspaces/milestones --jq '.[] | "\(.number)\t\(.title)\t\(.open_issues) open/\(.closed_issues) closed"'`
3. **Triage queue** — `gh issue list --label needs-triage --json number,title,labels,createdAt`
4. **Unpublished feedback** — list rows via the feedback agent API
   (`infra/feedback-store/CONTRACT.md` § Agent API), status `new`.
5. **Reality check** — `gh pr list --state merged --limit 15`: what shipped
   since the roadmap last moved; note open issues whose work looks done.

Briefing shape: one line per lane on milestone posture, the triage queue with
a first-guess disposition each, and anything drifted enough to challenge.

## Dispositions

Every intake item gets exactly one, recorded where it's durable:

| Disposition | Action | Record |
|---|---|---|
| **Duplicate** | Propose closure, link the canonical issue | Comment on the dup; owner closes with native reason |
| **Scope-mod** | Fold into an existing issue | Comment on that issue proposing the amended scope |
| **New ticket** | Create the issue | Labels per `docs/agents/triage-labels.md`; one-session scope; `requested_evidence` when the work needs proof |
| **Reprioritize** | Propose milestone add/remove/resequence | Comment or session brief; state what moves down, not just up |
| **Challenge** | Written case against existing work | Comment on the challenged issue/milestone; evidence, not vibes |
| **Decline** | Not worth a ticket | Feedback-row note (API) or a one-line comment; say why |

After recording a disposition on an issue: remove `needs-triage`, apply
lane/dimension labels. For feedback rows: update status (`triaged`, `planned`,
`resolved`, `wont_fix`) and notes via the agent API; publish rows that become
tickets through the guarded publish path so dedup and audit hold.

## Roadmap edits

When triage changes strategic posture — a band moves, an item promotes, a
milestone theme closes — edit `backlog/ROADMAP.md` and ship the diff as a PR.
Keep the edit honest to the file's conventions (bands, index, alignment
table). The owner merges.

## Session close

- Sweep: every touched intake item has a recorded disposition; no
  `needs-triage` label survives on an issue you triaged.
- Journal: one entry in `~/.ai-memory/mara-fielding/journal/` — decisions
  proposed, owner calls observed, calibration notes.
- End with the open decisions that are the owner's, each with a
  recommendation.
