# Workflow Dashboard — Design Spec

A self-contained web dashboard served from the durable-workflows bootstrap process. Shows workflow execution state with live updates, step inspection, and inline human-in-the-loop actions.

## Goals

- **Before**: See workflow list and step flow at a glance
- **During**: Watch steps complete in real-time, see running/pending states
- **After**: Inspect step outputs, durations, errors
- **Interact**: Approve/reject human-in-the-loop workflows from the browser

## Architecture

Bootstrap already runs a long-lived PGlite socket server. We add an HTTP server on a separate auto-assigned port alongside it.

```
bootstrap.ts
├── PGlite + Socket Server (:auto)    ← existing
└── HTTP Server (:auto)               ← new
    ├── GET /                          → serves assets/dashboard.html
    ├── GET /api/workflows             → workflow list (JSON)
    ├── GET /api/workflows/:id/steps   → step trace (JSON)
    └── POST /api/workflows/:id/send   → send message to workflow
```

The HTTP port is written to `connection.json` alongside the existing socket port:
```json
{
  "databaseUrl": "postgresql://...",
  "port": 50012,
  "httpPort": 50013,
  "pid": 12345,
  "mode": "embedded"
}
```

`npm run dashboard` prints the URL. Opening it in a browser shows the full UI.

## Asset

Single file: `durable-workflows/assets/dashboard.html`. Embedded CSS + JS, no build step, no external dependencies. Fonts loaded from Google Fonts CDN (JetBrains Mono, Instrument Serif).

## Design System

Matches the existing web app in `web/`:

| Token | Value |
|-------|-------|
| `--bg-primary` | `#0e1117` |
| `--bg-surface` | `#141821` |
| `--bg-elevated` | `#1a1f2e` |
| `--border` | `#242a3a` |
| `--border-subtle` | `#1c2233` |
| `--text-primary` | `#d4dae8` |
| `--text-secondary` | `#5a6580` |
| `--text-tertiary` | `#3a4258` |
| `--accent` | `#a6ffdf` (mint) |
| `--accent-dim` | `rgba(166,255,223,0.06)` |
| `--accent-glow` | `rgba(166,255,223,0.12)` |
| `--status-running` | `#ffd07e` (gold) |
| `--status-error` | `#f85149` (red) |
| `--status-waiting` | `#c4a1ff` (purple) |

Typography: JetBrains Mono for all UI, Instrument Serif italic for headings. No CSS framework — vanilla CSS with variables.

## Error Display

Failed steps render with a red-tinted card background (`rgba(248,81,73,0.08)`) and a red left border. The error message is shown inline below the step name in a monospace block — no click-to-expand needed for errors, they're always visible. In the step flow, the chain visually breaks at the failure point: the failed step gets a red fill, and subsequent steps render as hollow gray (never ran).

## Empty State

When no workflows exist, the main panel shows centered text: "No workflows yet" in serif italic, with a code snippet below:

```
npx tsx templates/basic-workflow.ts
```

The sidebar shows "0 workflows" in secondary text. No loading spinner, no skeleton — just the empty message immediately.

## Layout

Two-pane: sidebar + main.

### Sidebar (220px)
- Workflow list sorted by most recent
- Each row: workflow name, short ID, step count, relative time
- Status badge: SUCCESS (mint), RUNNING (gold pulse), ERROR (red), WAITING (purple pulse)
- Active workflow highlighted with `3px` left border accent
- Click to select

### Main Panel
- **Header**: Workflow name (serif italic), full ID, status badge, input args (collapsed if >1 line)
- **Step flow**: Horizontal chain of step chips connected by arrows. Color-coded by state: done (mint fill), running (gold border + pulse), pending (dashed gray), waiting (purple border + pulse)
- **Step cards**: Vertical list below the flow. Click to expand output. Shows step name, duration, status icon. Expanded view shows JSON output in a code block.
- **Connection indicator**: Top-right, green dot + "connected" when polling succeeds

## Complex Flow Patterns

### Branching (fan-out / fan-in)
DBOS steps don't carry an explicit `childWorkflowID`. Detection heuristic: when a step's output is a string that matches another workflow's `workflowID`, that step is a fork point and the matched workflow is the child. The API enriches step data with a `childWorkflows: string[]` array using this cross-reference. Parallel children render as vertical lanes side by side. A merge step (the next step in the parent after the fork) renders below with converging lines.

### Cycles (agent loops)
When the same step name appears multiple times (incrementing `functionID`), the dashboard detects a loop. Renders as:
- A rounded container with a badge: `loop · iter N/max`
- Inside: the repeating step(s)
- Below: "Loop History" showing each iteration as a compact chip with the step output preview and duration

### Human-in-the-loop (recv/send)
A step calling `DBOS.recv()` appears as PENDING with no output. The dashboard renders:
- Purple accent, pulsing ring indicator
- "WAITING FOR INPUT" badge
- Topic name displayed
- Timeout countdown
- **Approve / Reject buttons** that POST to `/api/workflows/:id/send`
- CLI fallback command shown below buttons

## API Endpoints

### `GET /api/workflows`
Returns the same data as `DBOSClient.listWorkflows()`. Supports `?status=PENDING,ERROR` filter.

### `GET /api/workflows/:id/steps`
Returns `DBOSClient.listWorkflowSteps(id)` plus the workflow metadata.

### `POST /api/workflows/:id/send`
Body: `{ "topic": "approval", "message": {"approved": true} }`
Calls `DBOSClient.send(id, message, topic)`. Used by the Approve/Reject buttons.

## Live Updates

The dashboard polls `GET /api/workflows` every 2 seconds. When the selected workflow changes status or gains new steps, the main panel updates. New steps animate in with a fade-in transition (0.3s ease-out).

When bootstrap stops or the connection drops, the indicator changes to "disconnected" (gray dot) and polling pauses with exponential backoff.

## Files Changed

| File | Change |
|------|--------|
| `assets/dashboard.html` | **New** — self-contained HTML/CSS/JS |
| `src/http-server.ts` | **New** — HTTP server with API routes |
| `src/db.ts` | Add `httpPort` to `ConnectionInfo` |
| `scripts/bootstrap.ts` | Start HTTP server, write `httpPort` to connection.json |
| `scripts/dashboard.ts` | Print URL when HTTP server is available |

## Out of Scope

- Authentication (local-only, same trust model as the socket)
- WebSocket/SSE for push updates (polling is sufficient for the step-level granularity)
- Workflow creation from the dashboard (use CLI or code)
- Mobile/responsive layout (desktop browser only)
