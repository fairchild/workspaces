# Spaces Dashboard — Design Outcomes

## Chosen Layout: Prototype D (`d-hybrid-dashboard.html`)

Two-level dashboard matching the `web/` design system.

```
┌──────────────────────────────────────────────────────────┐
│  Spaces  [Dashboard]                        fairchild [F]│
├──────────┬───────────────────────────┬───────────────────┤
│ REPOS    │ GLOBAL: aggregate stats   │ ACTIVITY          │
│          │ + per-repo summary cards  │ merged feed       │
│ ● work.. │                           │ from all repos    │
│ ● homep. │ REPO: scoped tabs         │                   │
│ ○ dotfi. │ [Dashboard|Schedule|Skills]│ or filtered to    │
│          │ stats → agents → pipeline │ selected repo     │
└──────────┴───────────────────────────┴───────────────────┘
```

**Global view** (topbar Dashboard tab): aggregate stats across repos, clickable repo cards.
**Per-repo view** (click a repo): three scoped tabs — Dashboard, Schedule, Skills.

### Design system

Matches `web/src/app/globals.css` exactly:

| Token | Value |
|-------|-------|
| Background | `#0e1117` with noise texture + scan lines |
| Accent | `#a6ffdf` (mint) with glow pulse on status dots |
| Display font | Instrument Serif (italic) |
| Body font | JetBrains Mono |
| Surfaces | `#141821` → `#1a1f2e` layered |
| Event colors | PR purple `#c4a1ff`, discussion blue `#7eb8ff`, push gold `#ffd07e`, issue coral `#ff9e7e` |

### Discovery API shape

```
GET /api/repos/:owner/:repo/agents → {
  agents: [{ name, role, status, skills }],
  skills: [{ name, description }],
  configFiles: [{ path, description }],
  pipeline: { ready: [], claimed: [], review: [], mergeable: [] }
}
```

Scans: `.agents/skills/*/SKILL.md`, `.agents/MEMORY.md`, `.agents/config/`, `CLAUDE.md`,
GitHub Issues API (`agent:*` labels), GitHub Discussions API.

---

## LLM Strategy: Level 2 (Curated Slots)

Ship deterministic first. Add LLM intelligence incrementally via structured JSON — never HTML.

| Phase | Slot | What the LLM decides | Fallback |
|-------|------|---------------------|----------|
| 1 | Hero insight | 1-2 sentence narrative about current state | Hidden |
| 2 | Agent annotations | Per-agent contextual one-liner | Raw status text |
| 3 | Section promotion | Which section matters most right now | Pipeline first |

The LLM produces ~500 tokens of JSON per request (Haiku-class, ~$0.001/call). Cached 10min.
Full exploration: `EXPLORATION-llm-driven-dashboard.md`.

---

## Files

| File | Purpose |
|------|---------|
| `d-hybrid-dashboard.html` | **Chosen prototype** — open in browser |
| `EXPLORATION-llm-driven-dashboard.md` | Full LLM architecture exploration |
| `a-command-center.html` | Earlier prototype (ops-focused, no tabs) |
| `b-team-directory.html` | Earlier prototype (agent-centric, global tabs) |
| `c-repo-explorer.html` | Earlier prototype (accordion tree view) |

## Next step

`backlog/done/spaces-agent-discovery-dashboard-plan.md` — Phase 1: build repo scanning + dashboard into the Next.js app.
