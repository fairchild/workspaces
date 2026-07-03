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

### Claimer identity

`claimer=` values follow `<harness>:<stable-id>` — e.g. `claude-code:session_01AB…`, `codex:silver-lake-refactor`, `gh-actions:run-28612644525`, `human:fairchild`. The branch, not the claimer, is what claim resolution keys on (below); `claimer` exists for audit trails, so prefer an identifier another agent or a human can trace back to a live session, thread, or run. If the harness exposes no stable identifier, use `<harness>:unknown` and note it in the trail.

## Claim resolution

The **branch** is the claim identity (agents often share a GitHub account, so assignee isn't reliable). Walking comments chronologically:

- `retried` resets the contest (no current winner)
- `advanced to=claimed` sets the winner only if currently empty (first-wins, catches take-time races)
- `rescued` overrides the current winner (deliberate takeover after timeout)

The earliest `advanced to=claimed` since the most recent `retried`, optionally overridden by a later `rescued`, is the canonical claimer.

## Operating

These conventions are operable directly via `gh issue` — open an issue, add the `claimed` label, post the right comment. The `backlog` skill (`add / take / advance / progress / cancel / fail / rescue / retry / maintain / status`) is a convenience layer that automates the patterns (auto-pick by priority, race-resolution at claim time, status counts) but isn't required for any of them. Mix both: skill for batch operations, raw `gh` for one-offs.

The protocol is also transport-agnostic: state lives in the labels and worklog comments, not in the tool that wrote them, so the GitHub MCP tools or raw REST with `GH_TOKEN` are as valid as `gh`. See `docs/agents/issue-tracker.md` § "When `gh` Is Unavailable" for the operation mapping (remote containers commonly lack `gh`).

Tasks are referenced by issue number — `take 42` or `take #42`. Titles are free text.

The label vocabulary above (`claimed` / `review` / `mergeable`) is shared with `docs/agents/triage-labels.md`; this file is the protocol-level view, that file is the canonical reference for what each label means in this repo.

## Co-existence with other automation

Two existing systems write the `claimed` / `review` / `mergeable` labels:

- **`.agents/skills/cofounder-contributor/scripts/sync-execution-state.py`** — owns the `agent` + `task` lifecycle. Promotes approved, unblocked issues to `ready`, to `claimed` on contributor claim, to `review` when a PR opens. Expires stale claims after 24h.
- **Managed PR reviewer** (`web/src/lib/agent-runtime/pr-review.ts`) — adds `mergeable` when an agent approves the linked PR; removes it on changes-requested.

These two systems and the `backlog` skill use **different claim comment formats**. Sync reads an HTML-comment marker embedded in the contributor's comment (`<!-- contributor:issue=N;status=...;agent=...;branch=... -->`); the skill posts a worklog line (`- <ts> advanced to=claimed claimer=... branch=...`). Sync ignores comments without its marker and treats the issue as unclaimed, so a skill-written `claimed` label on a sync-managed issue gets reverted to `ready` on the next sync pass.

This carves a clean operational split:

- **`agent` + `task` issues — do not use the skill.** Peter Planner creates them, owner approval routes through `sync-execution-state.py`, April/Plat claim via the contributor runtime which writes sync's marker. `backlog take`/`advance`/`rescue` on these issues fights sync and loses. Operate them through the agent automation paths.
- **All other issues — the skill is the only driver.** Sync gates on `AGENT_LANE_LABEL in current_labels and AGENT_TASK_LABEL in current_labels`, so issues missing either label are untouched. Use `backlog` freely for one-offs, scratch work, manual follow-ups, anything outside the auto-managed lane.
- **`cancel` / `fail` are safe everywhere.** Closing an issue is permanent; sync only ever adds labels to open issues, never reopens.

The protocol-first framing earlier in this doc is what makes the agent automation work without the skill: a Matt Pocock agent or a human operating `gh issue` directly can participate in the `agent` + `task` lane using the same labels and comment conventions sync already understands.

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

Closing an arc — milestone done, or a plan moving to `backlog/done/` — includes running the `retro` skill (`.agents/skills/retro/SKILL.md`); the archive commit and the retro's encodings usually travel together.
