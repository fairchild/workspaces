# Agent Team

Workspaces has a founding team of AI agents that propose improvements, review each other's work, and plan approved ideas into actionable issues. The goal is autonomous development with human approval gating — the repo advances itself, guided by the owner.

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
    2. Check in-progress issues → suggest next steps
    3. Read new discussion comments → react
    4. If nothing needs attention → propose new [idea]
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
    5. Marks [idea][endorsed]
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

### Approval Keywords

Reply to any `[idea]` discussion with one of these to trigger Peter Planner:

> yes, let's do it, plan it, approved, go ahead, ship it, lgtm, do it

The reply can include modifications — Peter reads the full thread and incorporates them.

### Discussion Lifecycle

```
[idea] New proposal          → open, awaiting review
[idea][endorsed] Approved    → planned into issues, work can begin
[shipped] Completed          → closed after delivery
```

## Files

| File | Purpose |
|------|---------|
| `.agents/prompts/april-clearwater.md` | April's persona and instructions |
| `.agents/prompts/plat-ironwood.md` | Plat's persona and instructions |
| `.agents/prompts/peter-planner.md` | Planner instructions |
| `.agents/config/peter-planner.toml` | Allowed planner labels + alias mapping |
| `.agents/scripts/run-contributor.py` | Shared runtime for contributor agents |
| `.agents/scripts/run-planner.py` | Shared runtime for Peter's planning workflow |
| `.agents/scripts/validate-agent-output.py` | Output validation + dedup checking |
| `scripts/ops-report.py` | Deterministic GitHub + perf reporting for the ops loop |
| `fixtures/ops-report/` | Checked-in replay packs for Observer dry runs and tests |
| `docs/ops/` | Checked-in ops timeline, snapshot JSON, and dashboard |
| `.github/workflows/agent-april.yml` | April's cron workflow |
| `.github/workflows/agent-plat.yml` | Plat's cron workflow |
| `.github/workflows/agent-peter.yml` | Event-triggered planner workflow |
| `.github/workflows/agent-observer.yml` | Weekly deterministic ops observer workflow |

## Runtime Layout

April, Plat, and Peter now use thin workflow wrappers. Their workflow YAML keeps only repository policy:

- schedules
- `workflow_dispatch`
- permissions
- concurrency
- checkout and tool setup

The shared contributor behavior lives in `.agents/scripts/run-contributor.py`:

1. gather repo and GitHub context
2. run Claude Code with the agent prompt
3. validate JSON output through `validate-agent-output.py`
4. either pretty-print validated JSON for dry runs or route the action back into GitHub

Peter Planner stays separate because it is event-driven and uses a different planning schema, but its workflow now delegates the orchestration to `.agents/scripts/run-planner.py`:

1. resolve manual dispatch vs owner approval comments
2. fetch discussion, labels, issues, and milestones
3. run Claude with the planner prompt
4. validate + normalize the plan (labels, milestone naming, markers)
5. reconcile retries, create or reuse GitHub artifacts, and update the discussion

Observer is deterministic rather than model-driven. Its workflow delegates to `scripts/ops-report.py`:

1. fetch idea discussions, issues, PRs, workflow runs, and perf snapshots
2. build `docs/ops/` style artifacts (`timeline.csv`, `latest-summary.json`, `dashboard.md`)
3. evaluate perf, CI, and throughput thresholds
4. optionally open one `[idea] [ops] ...` discussion when the loop needs hardening

For manual dry runs, `scripts/ops-report.py` also accepts `--fixtures-dir fixtures/ops-report/<scenario>` and replays synthetic inputs through the same reporting and breach-selection logic. Those fixture runs never update `docs/ops/` and never create GitHub discussions.

## Reliability

- **JSON output format** — agents output structured JSON in code fences, validated before posting (replaces fragile sed-based delimiter parsing)
- **Dedup checking** — proposed titles are compared against open discussions before posting
- **GraphQL for Discussions** — GitHub REST API doesn't support Discussions; all queries use GraphQL
- **Early filtering** — planner workflow skips non-owner comments at the job level (no wasted compute)
- **Shell safety** — event context passed via env vars, body content via temp files
- **Catalog-backed labels** — Peter can only use repo-managed labels from `.agents/config/peter-planner.toml`, with alias normalization for common CI/platform terms
- **Idempotent planning markers** — planner comments, milestone descriptions, and issue bodies carry machine markers so retries reuse existing artifacts instead of leaking duplicates
- **Discussion token override** — `permissions.discussions: write` is enough for comments, issues, and milestones, but GitHub's built-in Actions token still cannot retitle discussions via `updateDiscussion` in this repo. `agent-peter.yml` therefore prefers the repo secret `PETER_DISCUSSION_TOKEN` when present, and the repo's default Actions workflow permission should stay at `write`
- **Simple operational memory** — GitHub stays the raw event source; `docs/ops/` stores small checked-in snapshots and dashboards instead of introducing a separate analytics service or database in v1
- **Replay fixtures stay separate from memory** — Observer scenario packs live in `fixtures/ops-report/` so synthetic dry-run inputs do not get confused with the real operational snapshots in `docs/ops/`

## Vision: Autonomous Development

This is the seed of a self-driving development loop. The current state and where we're headed:

### Phase 1: Propose + Plan (current)
Agents propose ideas and review each other's work. Human approves. Planner creates issues.

### Phase 2: Memory
Add persistent memory so agents build context across sessions — what shipped, what worked, what didn't. They stop re-proposing similar ideas and develop a sense of project trajectory.

### Phase 3: Execute
Approved and planned issues get picked up by agents that create branches, write code, open PRs. Human reviews PRs.

### Phase 4: Evaluate
After work ships, agents assess impact — did the change improve the codebase? Did tests pass? Did performance hold? Evaluation feeds back into ideation priorities.

### Phase 5: Multi-agent, multi-model
Add more agents (Codex, other models) with different perspectives. User feedback signals (usage patterns, bug reports) flow into the ideation context. The team grows and diversifies.

The human remains the final authority at every stage. Agents propose, plan, and eventually execute — but nothing ships without explicit approval. The system gets more autonomous over time, but the owner always has the steering wheel.
