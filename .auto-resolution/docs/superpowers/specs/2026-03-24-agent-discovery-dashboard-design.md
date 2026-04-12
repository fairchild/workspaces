# Agent Discovery Dashboard — Phase 1 Design

## Problem

The Spaces web app at `spaces.cloudcompute.com` has auth and a webhook event feed, but no way to discover what AI agent setup exists across repos. The core value — "see your agent teams at a glance" — is missing.

## Scope

Phase 1 delivers: repo selection, agent discovery via GitHub Contents API, and issue pipeline kanban. No Discussions API, no LLM insights, no Schedule/Skills tabs (those are Phase 2+).

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Layout | Prototype D (3-column) | Matches existing web app layout; validated in prototype review |
| Data sources | Repos + .agents/ scan + Issues API | Pipeline kanban is the signature feature; Discussions deferred |
| Repo population | User-selected from sorted list | `GET /user/repos?sort=pushed` — user picks which to monitor |
| Onboarding | Full-screen repo selector | First visit shows selector; sidebar "+" button for later additions |
| Pipeline columns | ready → claimed → review → mergeable | `agent:task` and `agent:decision` shown as badges on cards |
| Design system | Existing tokens | Instrument Serif, JetBrains Mono, mint `#a6ffdf`, dark surfaces |
| Caching | 5min repos, 15min agent scans, 5min issues | Avoids GitHub rate limits while keeping data fresh |

## GitHub Token Access

Better Auth stores the user's GitHub access token in its `account` table (columns: `accessToken`, `providerId`). To make authenticated GitHub API calls:

1. **Add `repo` scope** to the GitHub social provider config in `auth.ts`:
   ```typescript
   github: {
     clientId: process.env.GITHUB_WEB_WORKSPACES_CLIENT_ID ?? "",
     clientSecret: process.env.GITHUB_WEB_WORKSPACES_CLIENT_SECRET ?? "",
     scope: ["repo"],
   }
   ```
2. **Retrieve token server-side** by querying the `account` table via `getDb()`:
   ```typescript
   const result = await getDb().execute({
     sql: "SELECT accessToken FROM account WHERE userId = ? AND providerId = 'github'",
     args: [session.user.id],
   });
   ```
3. **Existing users** who authorized before the scope change will need to re-authorize. The GitHub API calls will return 403 for insufficient scope — handle this by prompting re-auth.

The `github.ts` client accepts the token per-request from the session context.

## User Flow

1. **Sign in** — GitHub OAuth via Better Auth (already built; needs `repo` scope added)
2. **Repo selector** (first visit) — full-screen picker, repos sorted by most recent push, `.agents/` detection shown as badge with agent count
3. **Dashboard** — 3-column view: repo sidebar, center panel (stats + agent team + pipeline), activity feed
4. **Add repos later** — "+" button in sidebar opens modal/dropdown reusing the selector component

## Architecture

### Repo Selector (Onboarding)

Full-screen page at `/setup`. Fetches `GET /user/repos?sort=pushed&per_page=100` from GitHub API. Agent detection badges load lazily as repos render (batch `.agents/` HEAD checks in groups of 10 to avoid excessive API calls). User checks repos to monitor, clicks "Continue with N repos". Selections stored in Turso `user_repos` table.

The dashboard layout (`layout.tsx`) checks for saved repos via a Turso query and redirects to `/setup` if none exist. This avoids adding a DB query to middleware on every request.

### Dashboard (Per-Repo View)

When a repo is selected in the sidebar, the center panel shows:

**Stats row**: 4 cards — agent count, skill count, open PRs, ready issues. Open PRs fetched via `GET /repos/{owner}/{repo}/pulls?state=open` (cached 5min alongside issues).

**Agent team grid**: Cards for each discovered agent. Phase 1 treats every `.agents/skills/*/` directory entry as an agent — the directory name is the agent name, role is parsed from SKILL.md frontmatter `description` field (or null), skills listed from subdirectory names. Status derived from `agent:*` labeled issues (active if any issue has `agent:claimed` or `agent:review` with matching assignee, idle otherwise).

**Issue pipeline kanban**: 4 columns matching these exact labels:
- `agent:ready` → Ready
- `agent:claimed` → Claimed
- `agent:review` → Review
- `agent:mergeable` → Mergeable

Issues fetched via `GET /repos/{owner}/{repo}/issues?labels=agent:ready` (one call per column). Issues that also carry `agent:task` or `agent:decision` labels show those as colored secondary badges on the card.

### Activity Feed

Existing webhook event feed (right column) continues unchanged. When a repo is selected, the feed filters to show only events for that repo. When no repo is selected (global view), shows all events.

## API Routes

```
GET  /api/repos                          → user's selected repos (from Turso)
POST /api/repos                          → save repo selections (full replace — sends complete list)
GET  /api/repos/[owner]/[repo]/agents    → agent scan + issue pipeline
```

`POST /api/repos` uses upsert-replace: deletes all existing `user_repos` for the user, inserts the new list. This handles both adding and removing repos without a separate DELETE endpoint.

### `GET /api/repos/[owner]/[repo]/agents` Response Shape

```typescript
interface AgentDiscoveryResponse {
  agents: Array<{
    name: string;
    role: string | null;
    status: "active" | "idle";
    skills: string[];
    lastAction: string | null;
  }>;
  skills: Array<{
    name: string;
    description: string;
  }>;
  configFiles: Array<{
    path: string;
    description: string;
  }>;
  pipeline: {
    ready: Issue[];
    claimed: Issue[];
    review: Issue[];
    mergeable: Issue[];
  };
  stats: {
    agentCount: number;
    skillCount: number;
    openPRs: number;     // from GET /repos/{owner}/{repo}/pulls?state=open
    readyIssues: number; // count of pipeline.ready
  };
}

interface Issue {
  number: number;
  title: string;
  labels: string[];
  assignee: string | null;
  url: string;
}
```

### Caching Strategy

Server-side TTL-based caching (pure TTL in Phase 1, no webhook-triggered invalidation):
- Repo list from GitHub: 5 minutes
- Agent directory scan: 15 minutes (use Git Trees API `GET /repos/{owner}/{repo}/git/trees/{sha}?recursive=1` to fetch entire `.agents/` tree in a single call instead of walking directories)
- Issue pipeline + open PRs: 5 minutes
- Cache key: `{userId}:{owner}/{repo}:{endpoint}`
- In-memory Map with TTL check — simple, no external cache dependency

### Error Handling

- **Loading**: Skeleton placeholders while GitHub API calls are in flight
- **403 (scope)**: Prompt user to re-authorize with updated GitHub OAuth scope
- **404**: Repo deleted or access revoked — show "repo not found" and offer removal
- **429 (rate limit)**: Show cached data with "data may be stale" indicator
- **Partial failure**: Show what succeeded; failed sections show inline error with retry

## Storage (Turso)

New table for repo selections:

```sql
CREATE TABLE IF NOT EXISTS user_repos (
  user_id TEXT NOT NULL,
  owner TEXT NOT NULL,
  repo TEXT NOT NULL,
  added_at TEXT NOT NULL DEFAULT (datetime('now')),
  PRIMARY KEY (user_id, owner, repo)
);
```

## Files

### New

| File | Purpose |
|------|---------|
| `web/src/lib/github.ts` | GitHub API client (repos, contents, issues) with caching |
| `web/src/lib/agent-discovery.ts` | Parse `.agents/` tree into structured agent/skill/config data |
| `web/src/app/api/repos/route.ts` | GET/POST user repo selections |
| `web/src/app/api/repos/[owner]/[repo]/agents/route.ts` | Agent scan + issue pipeline |
| `web/src/app/setup/page.tsx` | Full-screen repo selector (onboarding) |
| `web/src/app/setup/page.module.css` | Repo selector styles |
| `web/src/app/dashboard/components/agent-card.tsx` | Individual agent card |
| `web/src/app/dashboard/components/agent-card.module.css` | Agent card styles |
| `web/src/app/dashboard/components/pipeline.tsx` | Kanban pipeline view |
| `web/src/app/dashboard/components/pipeline.module.css` | Pipeline styles |

### Modified

| File | Change |
|------|--------|
| `web/src/app/dashboard/page.tsx` | Add repo selection state, fetch agent data for selected repo |
| `web/src/app/dashboard/components/sidebar.tsx` | Show user's repos with agent count badges, "+" button |
| `web/src/app/dashboard/components/main-panel.tsx` | Replace placeholder stats with agent stats, team grid, pipeline |
| `web/src/lib/types.ts` | Add agent, pipeline, and repo selection types |
| `web/src/app/dashboard/layout.tsx` | Check for saved repos, redirect to `/setup` if none |
| `web/src/lib/auth.ts` | Add `scope: ["repo"]` to GitHub social provider |

## Acceptance Criteria

- [ ] First-time user sees full-screen repo selector with repos sorted by recent push
- [ ] Repos with `.agents/` directories show agent count badge in selector
- [ ] Selected repos persist in Turso across sessions
- [ ] Sidebar shows selected repos with agent count and open issue count
- [ ] "+" button in sidebar lets user add more repos
- [ ] Selecting a repo shows stats row (agents, skills, open PRs, ready issues)
- [ ] Agent team grid shows discovered agents with status and skills
- [ ] Pipeline kanban shows `agent:*` labeled issues in correct columns
- [ ] `agent:task` and `agent:decision` appear as badges on pipeline cards
- [ ] Activity feed filters to selected repo
- [ ] Repos without `.agents/` show "no agent setup" state
- [ ] GitHub API responses cached (5min repos, 15min agent scans, 5min issues)
- [ ] Design matches existing tokens (Instrument Serif, JetBrains Mono, mint, dark)

## Rollback

Each component is additive. The existing webhook event feed continues unchanged. Removing agent discovery means deleting the new files and reverting imports in the modified files. The `/setup` route and `user_repos` table are self-contained.

## References

- Validated prototype: `prototypes/spaces-dashboard/d-hybrid-dashboard.html`
- Design outcomes: `prototypes/spaces-dashboard/README.md`
- Existing backlog plan: `backlog/spaces-agent-discovery-dashboard-plan.md`
- Design tokens: `web/src/app/globals.css`
- Agent structure: `.agents/skills/*/SKILL.md`, `.agents/MEMORY.md`, `.agents/config/`
