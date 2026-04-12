# Workflow Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a self-contained web dashboard to the durable-workflows bootstrap process that shows workflow execution state with live updates, step inspection, and human-in-the-loop actions.

**Architecture:** Bootstrap's long-lived process gets an HTTP server (Node `http` module) alongside the existing PGlite socket. It serves a single HTML file and three JSON API endpoints. The HTML file is fully self-contained (embedded CSS + JS, no build step). DBOSClient handles all database queries.

**Tech Stack:** Node `http` module, vanilla HTML/CSS/JS, DBOSClient from `@dbos-inc/dbos-sdk`

**Spec:** `docs/superpowers/specs/2026-03-30-workflow-dashboard-design.md`

---

## File Structure

| File | Responsibility |
|------|---------------|
| `durable-workflows/src/db.ts` | Add `httpPort` to `ConnectionInfo` |
| `durable-workflows/src/http-server.ts` | HTTP server: static file serving + 3 API routes |
| `durable-workflows/assets/dashboard.html` | Self-contained dashboard UI |
| `durable-workflows/scripts/bootstrap.ts` | Start HTTP server, write `httpPort`, print URL |
| `durable-workflows/scripts/dashboard.ts` | Print dashboard URL when available, fall back to CLI table |

---

### Task 1: Add `httpPort` to ConnectionInfo

**Files:**
- Modify: `durable-workflows/src/db.ts:12-17`

- [ ] **Step 1: Add httpPort field to ConnectionInfo interface**

In `durable-workflows/src/db.ts`, update the `ConnectionInfo` interface:

```typescript
export interface ConnectionInfo {
  databaseUrl: string;
  port: number | null;
  httpPort?: number | null;
  pid: number;
  mode: "embedded" | "external";
}
```

The field is optional so existing `connection.json` files without it still parse correctly.

- [ ] **Step 2: Verify existing code still compiles**

Run: `cd durable-workflows && npx tsc --noEmit`
Expected: No errors (the field is optional, nothing breaks)

- [ ] **Step 3: Commit**

```bash
git add durable-workflows/src/db.ts
git commit -m "feat(dashboard): add httpPort to ConnectionInfo"
```

---

### Task 2: Create HTTP server module

**Files:**
- Create: `durable-workflows/src/http-server.ts`

- [ ] **Step 1: Create the HTTP server with static file serving and API routes**

Create `durable-workflows/src/http-server.ts`:

```typescript
/**
 * HTTP server for the workflow dashboard.
 * Serves dashboard.html and JSON API endpoints using DBOSClient.
 */

import { createServer, IncomingMessage, ServerResponse } from "node:http";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { DBOSClient } from "@dbos-inc/dbos-sdk";

const ASSETS_DIR = resolve(import.meta.dirname, "../assets");

let client: DBOSClient | null = null;

function json(res: ServerResponse, data: unknown, status = 200) {
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
  });
  res.end(JSON.stringify(data));
}

function html(res: ServerResponse, body: string) {
  res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
  res.end(body);
}

async function handleRequest(req: IncomingMessage, res: ServerResponse) {
  const url = new URL(req.url ?? "/", `http://${req.headers.host}`);
  const path = url.pathname;

  try {
    // Static: serve dashboard.html
    if (path === "/" || path === "/index.html") {
      const file = readFileSync(resolve(ASSETS_DIR, "dashboard.html"), "utf-8");
      return html(res, file);
    }

    // API: list workflows
    if (path === "/api/workflows" && req.method === "GET") {
      if (!client) return json(res, { error: "Not connected" }, 503);

      const statusParam = url.searchParams.get("status");
      const filter: Record<string, unknown> = { sortDesc: true, limit: 100 };
      if (statusParam) {
        filter.status = statusParam.split(",");
      }

      const workflows = await client.listWorkflows(filter as any);

      // Enrich with step counts
      const enriched = await Promise.all(
        workflows.map(async (wf) => {
          let stepCount = 0;
          try {
            const steps = await client!.listWorkflowSteps(wf.workflowID);
            stepCount = steps.length;
          } catch {}
          return { ...wf, stepCount };
        }),
      );

      return json(res, enriched);
    }

    // API: get workflow steps
    const stepsMatch = path.match(/^\/api\/workflows\/([^/]+)\/steps$/);
    if (stepsMatch && req.method === "GET") {
      if (!client) return json(res, { error: "Not connected" }, 503);

      const id = stepsMatch[1];
      const [wf, steps] = await Promise.all([
        client.getWorkflow(id),
        client.listWorkflowSteps(id),
      ]);

      if (!wf) return json(res, { error: "Workflow not found" }, 404);

      return json(res, { workflow: wf, steps });
    }

    // API: send message to workflow
    const sendMatch = path.match(/^\/api\/workflows\/([^/]+)\/send$/);
    if (sendMatch && req.method === "POST") {
      if (!client) return json(res, { error: "Not connected" }, 503);

      const id = sendMatch[1];
      const body = await readBody(req);
      const { topic, message } = JSON.parse(body);

      await client.send(id, message, topic);
      return json(res, { ok: true });
    }

    // CORS preflight
    if (req.method === "OPTIONS") {
      res.writeHead(204, {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type",
      });
      return res.end();
    }

    // 404
    json(res, { error: "Not found" }, 404);
  } catch (err: any) {
    json(res, { error: err.message ?? "Internal error" }, 500);
  }
}

function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => resolve(Buffer.concat(chunks).toString()));
    req.on("error", reject);
  });
}

export interface HttpServerHandle {
  port: number;
  close: () => Promise<void>;
}

/** Start the dashboard HTTP server on an auto-assigned port. */
export async function startHttpServer(databaseUrl: string): Promise<HttpServerHandle> {
  client = await DBOSClient.create({ systemDatabaseUrl: databaseUrl });

  const server = createServer(handleRequest);

  return new Promise((resolve, reject) => {
    server.listen(0, "127.0.0.1", () => {
      const addr = server.address();
      if (!addr || typeof addr === "string") {
        return reject(new Error("Failed to get server address"));
      }

      resolve({
        port: addr.port,
        close: async () => {
          server.close();
          if (client) {
            await client.destroy();
            client = null;
          }
        },
      });
    });

    server.on("error", reject);
  });
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd durable-workflows && npx tsc --noEmit`
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add durable-workflows/src/http-server.ts
git commit -m "feat(dashboard): add HTTP server with API routes"
```

---

### Task 3: Wire HTTP server into bootstrap

**Files:**
- Modify: `durable-workflows/scripts/bootstrap.ts:1-67`

- [ ] **Step 1: Import and start HTTP server in bootstrap**

In `durable-workflows/scripts/bootstrap.ts`, add the import at the top alongside existing imports:

```typescript
import { startHttpServer, type HttpServerHandle } from "../src/http-server.js";
```

After `DBOS.launch()` and `readConnectionInfo()` (around line 37), add the HTTP server startup:

```typescript
  // Start dashboard HTTP server
  let httpServer: HttpServerHandle | null = null;
  if (info) {
    try {
      httpServer = await startHttpServer(info.databaseUrl);
      // Update connection.json with httpPort
      const { writeConnectionInfo } = await import("../src/db.js");
      writeConnectionInfo({ ...info, httpPort: httpServer.port });
      console.log(`  Dashboard: http://127.0.0.1:${httpServer.port}`);
    } catch (err: any) {
      console.warn(`  Dashboard server failed: ${err.message}`);
    }
  }
```

Note: `writeConnectionInfo` is currently not exported. We need to export it from `db.ts` first (see step 2).

In the shutdown handler (the `shutdown` async function inside the `if (info?.mode === "embedded")` block), add HTTP server cleanup before DBOS shutdown:

```typescript
    const shutdown = async () => {
      console.log("\nShutting down...");
      if (httpServer) await httpServer.close();
      await DBOS.shutdown();
      await shutdownEmbedded();
      removeConnectionInfo();
      process.exit(0);
    };
```

- [ ] **Step 2: Export writeConnectionInfo from db.ts**

In `durable-workflows/src/db.ts`, the `writeConnectionInfo` function (line 83) is currently not exported. Change:

```typescript
function writeConnectionInfo(info: ConnectionInfo): void {
```

to:

```typescript
export function writeConnectionInfo(info: ConnectionInfo): void {
```

- [ ] **Step 3: Verify it compiles**

Run: `cd durable-workflows && npx tsc --noEmit`
Expected: No errors

- [ ] **Step 4: Commit**

```bash
git add durable-workflows/scripts/bootstrap.ts durable-workflows/src/db.ts
git commit -m "feat(dashboard): wire HTTP server into bootstrap lifecycle"
```

---

### Task 4: Create the dashboard HTML

**Files:**
- Create: `durable-workflows/assets/dashboard.html`

This is the largest task. The HTML file is self-contained with embedded CSS and JS.

- [ ] **Step 1: Create assets directory and dashboard.html**

Create `durable-workflows/assets/dashboard.html`. The file has three sections:

**CSS** must include:
- Design tokens as CSS variables matching the spec (see spec "Design System" table)
- Google Fonts import: JetBrains Mono 400/500/600, Instrument Serif 400 italic
- Two-pane layout: 220px sidebar + fluid main
- Status badge styles: `.status-SUCCESS` (mint), `.status-PENDING/.status-ENQUEUED` (gold pulse), `.status-ERROR` (red), waiting states (purple pulse)
- Step flow chips: horizontal chain with `→` connectors, color-coded by state
- Step cards: expandable, with JSON output in `<pre>` blocks
- Error card: red-tinted background `rgba(248,81,73,0.08)`, red left border, error always visible
- Empty state: centered, serif italic heading
- Connection indicator: top-right dot
- Animations: `@keyframes pulse` for running/waiting states, `fade-in` for new steps

**HTML structure:**

```html
<div class="app">
  <aside class="sidebar">
    <div class="sidebar-header">Workflows</div>
    <div class="sidebar-count"></div>
    <div class="workflow-list"></div>
  </aside>
  <main class="main">
    <div class="connection-indicator"></div>
    <div class="empty-state">
      <h2>No workflows yet</h2>
      <code>npx tsx templates/basic-workflow.ts</code>
    </div>
    <div class="workflow-detail" style="display:none">
      <div class="detail-header"></div>
      <div class="step-flow"></div>
      <div class="step-cards"></div>
    </div>
  </main>
</div>
```

**JavaScript** must include:

State:
```javascript
let workflows = [];
let selectedId = null;
let connected = false;
let pollTimer = null;
let backoffMs = 2000;
```

`fetchWorkflows()`:
- `GET /api/workflows`
- On success: set `connected = true`, reset `backoffMs = 2000`, update sidebar
- On error: set `connected = false`, increase `backoffMs = Math.min(backoffMs * 2, 30000)`

`fetchSteps(workflowId)`:
- `GET /api/workflows/${workflowId}/steps`
- Returns `{ workflow, steps }`

`sendMessage(workflowId, topic, message)`:
- `POST /api/workflows/${workflowId}/send` with JSON body
- Used by approve/reject buttons

`renderSidebar(workflows)`:
- Sort by `updatedAt` descending
- For each workflow: render name, short ID (first 8 chars), step count, relative time
- Status badge with icon and class
- Click handler sets `selectedId` and calls `renderDetail()`
- If no workflows: show "0 workflows" in `.sidebar-count`

`renderDetail(workflow, steps)`:
- **Header**: workflow name (serif italic `<h1>`), full ID, status badge, input args (collapsed `<details>` if array length > 1)
- **Step flow**: horizontal chain of chips. For each step:
  - Done: mint fill (`var(--accent)` bg with dark text)
  - Running: gold border + pulse animation
  - Error: red fill, chain breaks here
  - Waiting (PENDING with no output): purple border + pulse
  - Steps after an error: hollow gray (dashed border, `var(--text-tertiary)` text)
  - Connected by `→` arrows in `var(--text-tertiary)`
  - If step has `childWorkflowID`: show a branch indicator icon
- **Step cards**: vertical list. For each step:
  - Step name, `#functionID`, duration badge
  - Status icon (checkmark, spinner, X, hourglass)
  - Click to expand: shows JSON output in `<pre><code>` with `var(--bg-primary)` background
  - Error steps: always expanded, red-tinted card, error message in monospace
  - Steps with `childWorkflowID`: clickable link to child workflow
  - PENDING steps with no output (recv waiting): purple card with "WAITING FOR INPUT" badge, topic name, approve/reject buttons

**Approve/Reject buttons for human-in-the-loop:**
```javascript
function renderApprovalButtons(workflowId, topic) {
  // Returns HTML string with two buttons
  // Approve: calls sendMessage(workflowId, topic, { approved: true })
  // Reject: calls sendMessage(workflowId, topic, { approved: false })
  // Also show CLI fallback:
  // npm run send -- --id <id> --topic <topic> --message '{"approved":true}'
}
```

**Cycle detection:**
```javascript
function detectLoops(steps) {
  // Group consecutive steps by name pattern
  // If same name appears 3+ times with incrementing functionID, it's a loop
  // Return: [{ name, iterations: [{functionID, output, duration}], startIdx, endIdx }]
}
```

In `renderDetail`, if `detectLoops(steps)` finds loops, render them inside a rounded container with `loop · iter N` badge instead of individual step chips.

**Polling loop:**
```javascript
function startPolling() {
  pollTimer = setInterval(async () => {
    await fetchWorkflows();
    renderSidebar(workflows);
    if (selectedId) {
      const detail = await fetchSteps(selectedId);
      if (detail) renderDetail(detail.workflow, detail.steps);
    }
    updateConnectionIndicator();
  }, backoffMs);
}
```

**Connection indicator:**
- Green dot + "connected" when `connected === true`
- Gray dot + "disconnected" when `connected === false`
- Red dot + "error" on API errors

**Relative time formatter** (same logic as dashboard.ts `formatAge`):
```javascript
function formatAge(epochMs) {
  const delta = Date.now() - epochMs;
  if (delta < 1000) return "just now";
  if (delta < 60000) return `${Math.floor(delta / 1000)}s ago`;
  if (delta < 3600000) return `${Math.floor(delta / 60000)} min ago`;
  if (delta < 86400000) return `${Math.floor(delta / 3600000)}h ago`;
  return `${Math.floor(delta / 86400000)}d ago`;
}
```

- [ ] **Step 2: Verify the file is well-formed**

Run: `cd durable-workflows && node -e "require('fs').readFileSync('assets/dashboard.html', 'utf-8'); console.log('OK')"`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add durable-workflows/assets/dashboard.html
git commit -m "feat(dashboard): self-contained web dashboard HTML"
```

---

### Task 5: Update CLI dashboard to print URL

**Files:**
- Modify: `durable-workflows/scripts/dashboard.ts:1-144`

- [ ] **Step 1: Add URL hint at top of CLI dashboard output**

At the top of the `main()` function in `scripts/dashboard.ts`, after creating the client (line 49), add:

```typescript
  // Print web dashboard URL if available
  const info = readConnectionInfo();
  if (info?.httpPort) {
    console.log(`\n  Web dashboard: http://127.0.0.1:${info.httpPort}\n`);
  }
```

Add the import at the top of the file:

```typescript
import { readConnectionInfo } from "../src/db.js";
```

- [ ] **Step 2: Verify it compiles**

Run: `cd durable-workflows && npx tsc --noEmit`
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add durable-workflows/scripts/dashboard.ts
git commit -m "feat(dashboard): print web dashboard URL in CLI output"
```

---

### Task 6: Manual integration test

- [ ] **Step 1: Start bootstrap and verify HTTP server starts**

```bash
cd durable-workflows
npm run bootstrap
```

Expected output includes a line like:
```
  Dashboard: http://127.0.0.1:<port>
```

Verify `connection.json` includes `httpPort`:
```bash
cat .dbos/connection.json
```

- [ ] **Step 2: Open dashboard in browser — verify empty state**

Open `http://127.0.0.1:<port>` in a browser.

Expected: Dark UI with "No workflows yet" centered, "0 workflows" in sidebar, green "connected" indicator.

- [ ] **Step 3: Run a workflow and verify it appears**

In another terminal:
```bash
cd durable-workflows
npx tsx templates/basic-workflow.ts
```

Within 2 seconds, the dashboard should show the workflow in the sidebar (SUCCESS, mint badge). Click it to see the step flow and step cards.

- [ ] **Step 4: Verify CLI dashboard prints URL**

```bash
npm run dashboard
```

Expected: Shows web dashboard URL at top, then the usual CLI table.

- [ ] **Step 5: Stop bootstrap and verify disconnected state**

Kill the bootstrap process. The dashboard's connection indicator should turn gray ("disconnected").

- [ ] **Step 6: Commit any fixes, then final commit**

```bash
git add -A durable-workflows/
git commit -m "feat(dashboard): integration verified"
```
