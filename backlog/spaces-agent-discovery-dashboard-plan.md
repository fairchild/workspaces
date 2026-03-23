---
topic: spaces-web
priority: 2
description: Build the agent discovery dashboard into the Next.js app at spaces.cloudcompute.com
---

# Spaces Agent Discovery Dashboard

## Problem Statement

The Spaces web app at spaces.cloudcompute.com has auth and a webhook event feed, but no way
for authenticated users to discover what AI agent setup exists across their GitHub repos. The
core value proposition — "see your agent teams at a glance" — is missing.

Users should be able to select repos and, for each one, see discovered agents, skills, config
files, the issue pipeline, agent schedule, and recent activity. This is the primary dashboard
experience.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Layout | Command Center (sidebar + center + activity) | Matches existing `web/` 3-column layout; user preferred this in prototype review |
| Tabs | Dashboard + Schedule + Skills | Dashboard is the ops view; Schedule and Skills pulled from Team Directory prototype |
| Design system | Match existing `web/` tokens exactly | Instrument Serif, JetBrains Mono, mint accent, noise/scanlines already established |
| Discovery method | GitHub Contents API scanning `.agents/` | Repos expose agent setup via filesystem convention, no special API needed |
| LLM integration | Level 2 (curated slots), deferred to Phase 2 | Ship deterministic first, add LLM insight banner + annotations incrementally |

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Topbar: Spaces [Dashboard|Schedule|Skills]  [user] │
├──────────┬──────────────────────────┬───────────────┤
│ Sidebar  │  Center panel            │ Activity feed │
│          │                          │               │
│ Repos    │  Stats row               │ PR opened     │
│ ● work.. │  Agent team grid         │ Review done   │
│ ● homep. │  Issue pipeline          │ Idea proposed │
│ ○ dotfi. │  (or Schedule/Skills)    │ CI passed     │
│          │                          │               │
└──────────┴──────────────────────────┴───────────────┘
```

Data flow:
```
1. User authenticates (Better Auth + GitHub OAuth — already working)
2. Fetch user's repos (GitHub API, cache 5min)
3. For each repo, scan for .agents/ (GitHub Contents API, cache 15min)
4. Extract: agents, skills, config files from filesystem
5. Fetch agent:* labeled issues (GitHub Issues API)
6. Fetch recent discussions (GitHub GraphQL)
7. Render dashboard with discovered data
```

## Implementation Phases

### Phase 1: Repo scanning + dashboard view

**Files to modify:**
- `web/src/app/dashboard/page.tsx` — Add repo selection state, replace simple stats with agent dashboard
- `web/src/app/dashboard/components/sidebar.tsx` — Add agent count badges, selection state
- `web/src/app/dashboard/components/main-panel.tsx` — Replace with agent stats, team grid, pipeline
- `web/src/app/dashboard/page.module.css` — Update grid for new content sections

**Files to create:**
- `web/src/lib/github.ts` — GitHub API client (Contents API for `.agents/` scanning, Issues API for pipeline)
- `web/src/lib/agent-discovery.ts` — Parse `.agents/` tree into structured agent/skill/config data
- `web/src/app/api/repos/[owner]/[repo]/agents/route.ts` — API route returning discovered agent setup
- `web/src/app/dashboard/components/agent-card.tsx` — Individual agent card component
- `web/src/app/dashboard/components/agent-card.module.css`
- `web/src/app/dashboard/components/pipeline.tsx` — Kanban pipeline (ready→claimed→review→mergeable)
- `web/src/app/dashboard/components/pipeline.module.css`

**Acceptance criteria:**
- [ ] Sidebar shows user's repos with agent count badges
- [ ] Selecting a repo shows stats (agents, skills, open PRs, ready issues)
- [ ] Agent team grid renders discovered agents with status, skills, last action
- [ ] Issue pipeline shows agent-labeled issues in correct columns
- [ ] Repos without `.agents/` show "no agent setup" state
- [ ] GitHub API responses cached (5min repos, 15min agent scans)

### Phase 2: Schedule + Skills tabs

**Files to create:**
- `web/src/app/dashboard/components/schedule-view.tsx` — Weekly schedule grid
- `web/src/app/dashboard/components/schedule-view.module.css`
- `web/src/app/dashboard/components/skills-view.tsx` — Skill inventory cards
- `web/src/app/dashboard/components/skills-view.module.css`

**Acceptance criteria:**
- [ ] Schedule tab shows weekly agent run grid (parsed from agent-team.md or config)
- [ ] Skills tab shows all discovered `.agents/skills/*/SKILL.md` with descriptions
- [ ] Both tabs follow existing design system (JetBrains Mono, mint accent, dark surfaces)

### Phase 3: LLM insight slots (optional, after Phase 1+2 stable)

**Files to create:**
- `web/src/app/api/insights/route.ts` — Server-side LLM call returning JSON slot decisions
- `web/src/app/dashboard/components/insight-banner.tsx` — Hero insight rendered from LLM JSON

**Acceptance criteria:**
- [ ] Insight banner streams in after shell renders
- [ ] Falls back gracefully if LLM slow/unavailable (banner simply hidden)
- [ ] LLM produces JSON decisions, never HTML

## Verification Commands

```bash
# Dev server
cd web && pnpm dev

# Typecheck
cd web && pnpm typecheck

# Lint
cd web && pnpm lint
```

## Rollback Plan

Each phase is additive. The existing webhook event dashboard continues to work unchanged.
New components are behind tab/route boundaries — removing a phase means deleting the
component files and reverting `page.tsx` imports.

## References

- **Validated prototype:** `infra/spaces-dashboard/prototypes/d-hybrid-dashboard.html` (open in browser to see the target)
- **Existing web app:** `.claude/worktrees/webui/web/` (Next.js, pnpm, Better Auth, CSS Modules)
- **Design tokens:** `web/src/app/globals.css` (all CSS variables, fonts, animations)
- **Agent structure to discover:** `.agents/skills/*/SKILL.md`, `.agents/MEMORY.md`, `.agents/config/`
- **LLM architecture exploration:** `infra/spaces-dashboard/prototypes/EXPLORATION-llm-driven-dashboard.md`
- **Agent team reference:** `docs/development/agent-team.md`
- **Existing Cloudflare infra:** `infra/cloudflare-webhook-relay/` (auth + events already deployed)
