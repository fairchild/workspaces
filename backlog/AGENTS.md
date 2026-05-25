# backlog/

`CLAUDE.md` here is a symlink to this file — read one, not both.

Task state lives in GitHub Issues on **fairchild/workspaces**. The repo's open issues are
the backlog — anything open is takeable. Non-conformant issues (random
feature requests, dormant bug reports) get triaged when a worker encounters
them; there's no marker label gating membership.

## State mapping

| State    | open/closed | labels                   |
|----------|-------------|--------------------------|
| todo     | open        | no in-flight labels      |
| claimed     | open        | `claimed` label     |
| review     | open        | `review` label     |
| mergeable     | open        | `mergeable` label     |
| done     | closed      | no `dead-letter` label       |
| failed   | closed      | `dead-letter` label          |

## Worklog

Every state transition and progress note is one comment on the issue, in this shape:

    - <ISO-8601 ts> <verb> [args] | <trail>

| Verb                       | Args / trail                                                |
|----------------------------|-------------------------------------------------------------|
| `advanced to=<state>`    | for `<first-in-flight>`: `claimer=<who>` `branch=<git-branch>`; for `done`: optional `\| PR=<url>`; intermediate transitions: no extra args |
| `progress`               | trail = `\| <note>`                                        |
| `cancelled`              | trail = `\| <reason>`                                      |
| `failed`                 | trail = `\| <reason>`                                      |
| `rescued`                | `claimer=<who>` `branch=<git-branch>`                   |
| `retried`                | trail = `\| <reason>`                                      |

## Claim resolution

The **branch** is the claim identity (agents often share a GitHub account, so assignee isn't reliable). Walking comments chronologically:

- `retried` resets the contest (no current winner)
- `advanced to=claimed` sets the winner only if currently empty (first-wins, catches take-time races)
- `rescued` overrides the current winner (deliberate takeover after timeout)

The earliest `advanced to=claimed` since the most recent `retried`, optionally overridden by a later `rescued`, is the canonical claimer.

## Operating

These conventions are operable directly via `gh issue` — open an issue, add the `claimed` label, post the right comment. The `backlog` skill (`add / take / advance / progress / cancel / fail / rescue / retry / maintain / status`) is a convenience layer that automates the patterns (auto-pick by priority, race-resolution at claim time, status counts) but isn't required for any of them. Mix both: skill for batch operations, raw `gh` for one-offs.

Tasks are referenced by issue number — `take 42` or `take #42`. Titles are free text.

The label vocabulary above (`claimed` / `review` / `mergeable`) is shared with `docs/agents/triage-labels.md`; this file is the protocol-level view, that file is the canonical reference for what each label means in this repo.

## Co-existence with other automation

The skill is not the sole writer of these labels. Two existing systems also drive transitions on `agent` + `task` issues:

- **`.agents/skills/cofounder-contributor/scripts/sync-execution-state.py`** — owns `agent` + `task` lifecycle. Promotes approved, unblocked issues to `ready`, then to `claimed` on contributor claim, then to `review` when a PR opens. Expires stale claims after 24h.
- **Managed PR reviewer** (`web/src/lib/agent-runtime/pr-review.ts`) — adds `mergeable` when an agent approves the linked PR; removes it on changes-requested.

Where the skill participates:

- **At claim (`take` / `advance` to `claimed`)** — skill writes the `claimed` label and posts the worklog comment with `branch=` for race resolution. Safe on `agent` + `task` issues because `sync-execution-state.py` does the same thing; the worklog comment is the source of truth either way.
- **Mid-pipeline (`claimed → review → mergeable`)** — let the external automation drive these transitions. The skill *can* `advance` here, but doing so on `agent` + `task` issues races with sync. For non-`agent`+`task` issues (personal work, scratch threads, things outside the pipeline) the skill drives the whole sequence itself.
- **At completion (`advance` from `mergeable` → `done`)** — skill closes the issue once merge has landed. Safe regardless of who set `mergeable`.
- **`cancel` / `fail` / `rescue` / `retry`** — terminal verbs; safe at any point.

This works because `current_claim` (skill internal) resolves ownership by walking branch-tagged worklog comments, not by reading the current label. External writers moving the label forward don't break the skill's view of who claimed the issue.

If you're claiming an `agent` + `task` issue and want to avoid double-writes, prefer the existing automation paths (Peter's planning → owner approval → `sync-execution-state.py`). Reach for `backlog take` on issues outside that pipeline, or when you want race-safe claim semantics for a manual pickup.

## Backend

`github-issues` — see the `backlog` skill's `references/backends/github-issues.md` for the script's behavior.

## Pipeline

todo → claimed → review → mergeable → done

(Each in-flight state has a label. `advance` moves an issue to the next state in this line — closes the issue when it reaches `done`. Add or remove intermediate stages by editing this line; declare each new state in `## Labels` below.)

## Labels

claimed: claimed
review: review
mergeable: mergeable
failed: dead-letter

(Each in-flight pipeline state maps to a label. Defaults to the state name itself; override here to align with an existing label vocabulary. `failed` is the special dead-letter terminal. Configurable at setup via `--label-<state>=<name>` and `--failed-label=<name>`; editing this section after `setup` requires `gh label rename` on the remote to keep the actual labels in sync.)

## ROADMAP

Strategic counterpart at `backlog/ROADMAP.md`. See the `backlog` skill's `references/roadmap.md`.
