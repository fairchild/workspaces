# Agent Team

Workspaces has a founding team of AI agents that propose improvements, review each other's work, plan approved ideas into actionable issues, and now pick up explicitly approved issues into PRs. The goal is autonomous development with human approval gating — the repo advances itself, guided by the owner.

If you need the operator-facing runbook for how to interact with and manage the agents, start with [agent-owner-protocol.md](/Users/fairchild/.codex/worktrees/7a0f/workspaces/docs/development/agent-owner-protocol.md).

## Team

### April Clearwater — Application Lead
Focuses on UI, terminal, workflows, user experience. Thinks about what the person at the keyboard experiences.

### Plat Ironwood — Platform Lead
Focuses on CI/CD, agent infrastructure, distribution, notifications, testing. Thinks about what breaks at 3am.

### Peter Planner
Converts approved ideas into GitHub Issues and Milestones. Activated when the owner approves a proposal.

### Observer
Gathers operational evidence from GitHub and the checked-in perf snapshots. Runs weekly, updates the ops timeline, and may open a focused `[idea] [ops] ...` discussion when thresholds are breached. For local validation, the same runtime can replay checked-in scenario packs from `fixtures/ops-report/` without touching GitHub.

All agents share core principles: quality over speed, hardening over feature expansion, calm/clean/intuitive UX without compromise.

## How It Works

```
Daily (weekdays, alternating who goes first, 30 min offset):

  Agent wakes up
    │
    1. Check open PRs → give code review
    2. Check own open PRs / claimed issues → keep them moving
    3. Check execution-approved ready issues → claim one and open/update a PR
    4. Read new discussion comments → react
    5. If nothing needs attention → propose new [idea]
    │
    Post to GitHub Discussions
    │
  Owner reviews, replies with approval keyword
    │
  Peter Planner (event-triggered)
    1. Replies "Working on it..."
    2. Reads full thread + owner's modifications
    3. Creates Issue(s) or Milestone + Issues
    4. Links discussion ↔ issues
    5. Posts a summary comment with the milestone link and execution approval instructions
    6. Marks [idea][endorsed]
    │
  Owner reacts 👍 on Peter's summary comment
    │
  Execution-state sync (next contributor wake-up)
    1. Applies `agent:ready` to approved, unblocked issues with no active PR/claim
    2. Applies `agent:claimed` to actively claimed issues
    3. Applies `agent:review` to issues with an open PR
    4. Expires claim-only issues after 24h if no PR was opened, including unassigning the agent
    │
  Next April / Plat wake-up
    1. Re-review open PRs they are blocking
    2. Review other open PRs
    3. Continue their own PRs / claimed issues
    4. Claim the highest-priority ready approved issue
    5. Push a branch + open/update a PR
    │
  Observer (weekly)
    1. Reads idea/issue/PR/workflow history
    2. Summarizes the closed loop into docs/ops artifacts
    3. Opens one [idea] [ops] discussion only if a threshold breach needs attention
```

### Schedule

| Day | First (7:00am PT) | Second (7:30am PT) |
|-----|--------------------|--------------------|
| Mon | April | Plat |
| Tue | Plat | April |
| Wed | April | Plat |
| Thu | Plat | April |
| Fri | April | Plat |

The 30-minute offset means the second agent sees the first's output and can comment on it.

Observer runs separately once a week on Monday at 13:30 UTC to evaluate loop health and evidence trends.

### On-Demand Mentions

Mention an agent by name in any issue or PR comment to summon them:

- `@april` — April Clearwater responds with her Application/UI perspective
- `@plat` — Plat Ironwood responds with his Platform/CI perspective
- `@peter` — Peter Planner redirects to Discussions (his planning workflow operates there)

Mention-triggered runs use the same contributor runtime with a directed message (`--message`), which overrides the normal priority order. The agent focuses on what was asked. Multiple agents can be mentioned in the same comment and will run in parallel.

Mention runs use separate concurrency groups (`agent-april-mention`, etc.) so they don't interfere with scheduled cron runs.

### Approval Keywords

Reply to any `[idea]` discussion with one of these to trigger Peter Planner:

> yes, let's do it, plan it, approved, go ahead, ship it, lgtm, do it

The reply can include modifications — Peter reads the full thread and incorporates them.

### Discussion Lifecycle

```
[idea] New proposal          → open, awaiting review
[idea][endorsed] Approved    → planned into issues
[idea][endorsed] + 👍 on Peter summary → execution-approved
`agent:ready` issue          → ready for a contributor to claim
`agent:claimed` issue        → claimed, agent assigned, working toward PR
`agent:review` issue         → PR opened, awaiting review
`agent:review` + `agent:mergeable` → agent approved, ready for owner merge
[shipped] Completed          → closed after delivery (PR merge auto-closes issue)
```

## Files

Prompt, runtime, and compatibility responsibilities now split cleanly:

- `.agents/skills/` holds the reusable workflow packages, prompt references, and runtime scripts
- `.agents/scripts/` keeps compatibility entrypoints for older automation paths

| File | Purpose |
|------|---------|
| `.agents/skills/cofounder-contributor/SKILL.md` | Shared contributor skill for April and Plat |
| `.agents/skills/cofounder-contributor/references/` | Persona prompt resources for April and Plat |
| `.agents/skills/cofounder-contributor/scripts/run-contributor.py` | Contributor runtime source of truth |
| `.agents/skills/cofounder-contributor/scripts/sync-execution-state.py` | Syncs discussion approval into `agent:ready` / `agent:claimed` / `agent:review` issue state |
| `.agents/skills/peter-planner/SKILL.md` | Planner skill for endorsed discussion → issues/milestone |
| `.agents/skills/peter-planner/references/peter-planner.md` | Planner prompt resource |
| `.agents/skills/peter-planner/config/peter-planner.toml` | Allowed planner labels + alias mapping |
| `.agents/skills/peter-planner/scripts/run-planner.py` | Planner runtime source of truth |
| `.agents/scripts/run-contributor.py` | Compatibility shim for existing automation |
| `.agents/scripts/run-planner.py` | Compatibility shim for existing automation |
| `.agents/scripts/validate-agent-output.py` | Compatibility shim for shared validation |
| `.agents/skills/drive/SKILL.md` | Manual milestone execution workflow after planning |
| `docs/development/agent-owner-protocol.md` | Owner-facing protocol for approving, steering, and merging agent work |
| `scripts/ops-report.py` | Deterministic GitHub + perf reporting for the ops loop |
| `fixtures/ops-report/` | Checked-in replay packs for Observer dry runs and tests |
| `docs/ops/` | Checked-in ops timeline, snapshot JSON, and dashboard |
| `.github/workflows/agent-april.yml` | April's cron workflow |
| `.github/workflows/agent-plat.yml` | Plat's cron workflow |
| `.github/workflows/agent-peter.yml` | Event-triggered planner workflow |
| `.github/workflows/agent-mention.yml` | `@april` / `@plat` / `@peter` mention-triggered workflow |
| `.github/workflows/_evidence.yml` | Reusable evidence workflow (build, test, screenshot, reconcile) |
| `.github/workflows/agent-observer.yml` | Weekly deterministic ops observer workflow |

## Runtime Layout

April, Plat, and Peter now use thin workflow wrappers. Their workflow YAML keeps only repository policy:

- schedules
- `workflow_dispatch`
- permissions
- concurrency
- checkout and tool setup

The shared contributor behavior now lives in `.agents/skills/cofounder-contributor/scripts/run-contributor.py` plus the execution-state sync script:

1. sync `agent:ready` / `agent:claimed` / `agent:review` from discussion approval, blockers, open PRs, and stale claims
2. gather repo and GitHub context
3. run Claude Code with the selected persona prompt
4. validate YAML frontmatter output through the shared validator
5. either pretty-print validated JSON for dry runs or route the action back into GitHub

When Peter has already planned a discussion, execution approval lives on Peter's summary comment. A 👍 reaction from the repo owner is the mission-level signal. The sync step turns that into explicit per-issue `agent:ready` state, transitions to `agent:review` when a PR opens, and expires `agent:claimed` issues after 24 hours when no PR exists (including unassigning the agent).

April and Plat workflows now invoke the skill runtime directly. The old `.agents/scripts/run-contributor.py` path remains only as a compatibility shim for any external callers that still depend on it.

Peter Planner stays separate because it is event-driven and uses a different planning schema, but its runtime source of truth now lives in `.agents/skills/peter-planner/scripts/run-planner.py`:

1. resolve manual dispatch vs owner approval comments
2. fetch discussion, labels, issues, and milestones
3. run Claude with the planner prompt
4. validate + normalize the plan (labels, milestone naming, markers)
5. reconcile retries, create or reuse GitHub artifacts, and update the discussion

The Peter workflow now invokes the skill runtime directly. The old `.agents/scripts/run-planner.py` path remains only as a compatibility shim for any external callers that still depend on it.

Observer is deterministic rather than model-driven. Its workflow delegates to `scripts/ops-report.py`:

1. fetch idea discussions, issues, PRs, workflow runs, and perf snapshots
2. build `docs/ops/` style artifacts (`timeline.csv`, `latest-summary.json`, `dashboard.md`)
3. evaluate perf, CI, and throughput thresholds
4. optionally open one `[idea] [ops] ...` discussion when the loop needs hardening

For manual dry runs, `scripts/ops-report.py` also accepts `--fixtures-dir fixtures/ops-report/<scenario>` and replays synthetic inputs through the same reporting and breach-selection logic. Those fixture runs never update `docs/ops/` and never create GitHub discussions.

## Reliability

- **YAML frontmatter output format** — agents output structured YAML frontmatter, validated before posting, with JSON fences retained only as a fallback parser path
- **Dedup checking** — proposed titles are compared against open discussions before posting
- **GraphQL for Discussions** — GitHub REST API doesn't support Discussions; all queries use GraphQL
- **Early filtering** — planner workflow skips non-owner comments at the job level (no wasted compute)
- **Shell safety** — event context passed via env vars, body content via temp files
- **Catalog-backed labels** — Peter can only use repo-managed labels from `.agents/skills/peter-planner/config/peter-planner.toml`, with alias normalization for common CI/platform terms
- **Idempotent planning markers** — planner comments, milestone descriptions, and issue bodies carry machine markers so retries reuse existing artifacts instead of leaking duplicates
- **Explicit execution-state labels** — contributor workflows translate mission approval into `agent:ready`, `agent:claimed`, and `agent:review`, so execution no longer depends on contributors reparsing discussion reactions on every decision
- **GitHub-native assignment tracking** — agents assign themselves to issues on claim, providing native GitHub filtering via `--assignee`; sync unassigns on stale-claim expiry
- **Additive mergeable signal** — `agent:mergeable` stacks on `agent:review` when an agent approves a PR, and is removed when changes are requested; it is not managed by sync
- **Stale-claim recovery** — claims without a PR automatically expire after 24 hours, return to `agent:ready`, and unassign the agent on the next sync pass
- **Discussion token override** — `permissions.discussions: write` is enough for comments, issues, and milestones, but GitHub's built-in Actions token still cannot retitle discussions via `updateDiscussion` in this repo. `agent-peter.yml` therefore prefers the repo secret `PETER_DISCUSSION_TOKEN` when present, and the repo's default Actions workflow permission should stay at `write`
- **OpenAI env compatibility** — agent runtimes treat `OPENAI_API_KEY` as the canonical provider variable and fall back to `GITHUB_CODESPACES_OPENAI_API_KEY` when present so local Codespaces-oriented `.env` files can still work without changing the runtime contract
- **Simple operational memory** — GitHub stays the raw event source; `docs/ops/` stores small checked-in snapshots and dashboards instead of introducing a separate analytics service or database in v1
- **Replay fixtures stay separate from memory** — Observer scenario packs live in `fixtures/ops-report/` so synthetic dry-run inputs do not get confused with the real operational snapshots in `docs/ops/`

## Vision: Autonomous Development

This is the seed of a self-driving development loop. The current state and where we're headed:

### Phase 1: Propose + Plan (current)
Agents propose ideas and review each other's work. Human approves. Planner creates issues.

### Phase 2: Memory
Add persistent memory so agents build context across sessions — what shipped, what worked, what didn't. They stop re-proposing similar ideas and develop a sense of project trajectory.

### Phase 3: Execute
Approved and planned issues get picked up by April and Plat after the owner reacts 👍 on Peter's summary comment. They create branches, write code, open PRs, and keep open PRs moving to closure. Peter defines the requested evidence for each issue, and the PR body must account for that evidence before review can clear. Human reviews PRs and remains the only merge authority.

The `$drive` skill remains the manual bridge for milestone-wide execution, but the standing contributor workflows can now autonomously pick up a single approved issue at their scheduled wake-up.

### Phase 4: Evaluate
After work ships, agents assess impact — did the change improve the codebase? Did tests pass? Did performance hold? Evaluation feeds back into ideation priorities.

### Phase 5: Multi-agent, multi-model
Add more agents (Codex, other models) with different perspectives. User feedback signals (usage patterns, bug reports) flow into the ideation context. The team grows and diversifies.

The human remains the final authority at every stage. Agents propose, plan, and eventually execute — but nothing ships without explicit approval. The system gets more autonomous over time, but the owner always has the steering wheel.
