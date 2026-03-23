# Spaces Dashboard Prototypes

Three self-contained HTML prototypes for the spaces.cloudcompute.com agent discovery dashboard.
Open any file directly in a browser — no build step needed. Each uses mock data that mirrors the
real `.agents/` structure discovered in `fairchild/workspaces`.

## How to try them

```bash
open infra/spaces-dashboard/prototypes/a-command-center.html
open infra/spaces-dashboard/prototypes/b-team-directory.html
open infra/spaces-dashboard/prototypes/c-repo-explorer.html
```

---

## Prototype A: Command Center

**File:** `a-command-center.html`

**Concept:** Ops-focused dashboard with a persistent sidebar of repos and a dense main panel.
Think mission control — you see everything at once for the selected repo.

**Layout:**
- Left sidebar: repo list with agent counts, click to switch
- Main panel: 4 stat cards (agents, skills, open PRs, ready issues) → agent team grid →
  Kanban issue pipeline (ready → claimed → review → mergeable) → activity feed → config files

**Best for:** Power users who want operational visibility. Shows the full pipeline state and
recent activity in a single scroll. The Kanban pipeline makes it obvious what agents are
working on and what's queued.

**Trade-offs:** Dense. May feel overwhelming for someone just discovering agents for the first
time. The sidebar nav assumes multiple repos — works great with 3+, feels empty with 1.

---

## Prototype B: Team Directory

**File:** `b-team-directory.html`

**Concept:** Agent-centric "people directory" — treats each agent as a team member with a rich
profile card. Has tabs for Team / Schedule / Skills views.

**Layout:**
- Top bar with tabs: Team (default), Schedule, Skills
- Repo filter chips: toggle which repos to include
- Team view: large profile cards with avatar, bio, status, repos they operate in, skill
  pills, and a mini timeline of recent actions
- Schedule view: weekly grid showing who runs when (Mon-Fri, 7:00/7:30am)
- Skills view: card grid of all discovered skills with descriptions and users

**Best for:** Understanding *who* the agents are before diving into what they're doing.
Makes the team feel tangible. The schedule view answers "when does stuff happen?" at a glance.
The repo chips make it natural to filter across multiple repos.

**Trade-offs:** Less operational detail per-repo (no pipeline view). Emphasizes personas over
workflow state. The tabs add a click before you get to schedule/skills.

---

## Prototype C: Repo Explorer

**File:** `c-repo-explorer.html`

**Concept:** Developer-oriented tree view. Each repo is an expandable accordion. Expanding it
reveals a structured tree: agents → skills → config files → discussions → issues, plus a
workflow diagram showing the full coordination loop.

**Layout:**
- Single scrollable page, no sidebar
- Each repo is a collapsible block with stats in the header
- Expanding reveals: agents (with status), skills (monospace names + descriptions),
  config files (paths + descriptions), discussions (with lifecycle state), issues (with
  agent labels), and a step-by-step workflow visualization

**Best for:** First-time discovery. "What exactly is set up in this repo?" Feels like
browsing a file tree. The workflow diagram at the bottom of each repo makes the coordination
model immediately legible. Clean and focused — one repo at a time.

**Trade-offs:** No cross-repo aggregation. You can't see "all agents across all repos" in one
view. Less real-time ops feel. The accordion pattern works well for 2-5 repos but would need
pagination for 20+.

---

## Discovery API Shape (future)

All three prototypes assume the same data shape, which maps to what we'd get from the GitHub
Contents API scanning each repo:

```
GET /api/repos/:owner/:repo/agents → {
  agents: [{ name, role, status, skills }],
  skills: [{ name, description }],
  configFiles: [{ path, description }],
  discussions: [{ title, status, author }],
  issues: [{ title, label }],
  pipeline: { ready: [], claimed: [], review: [], mergeable: [] }
}
```

The scan checks for:
- `.agents/skills/*/SKILL.md` → skill inventory
- `.agents/skills/*/references/*.md` → agent personas
- `.agents/MEMORY.md` → shared memory existence
- `.agents/config/` → configuration files
- `CLAUDE.md` / `AGENTS.md` → agent context
- GitHub Issues API with `agent:*` labels → pipeline state
- GitHub Discussions API → coordination state
