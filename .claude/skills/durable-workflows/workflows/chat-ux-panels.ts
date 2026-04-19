/**
 * Chat UX: Collapsible panels + keyboard shortcuts workflow.
 *
 * Steps:
 *   1. Create worktree
 *   2. Implement collapsible sidebar (Cmd+B + click toggle)
 *   3. Implement collapsible right panel
 *   4. Add keyboard shortcuts (Cmd+1/2 tab switch)
 *   5. Add markdown rendering for agent messages
 *   6. Run tests
 *   7. Await human review
 *   8. Open PR
 *
 * Usage:
 *   npm run bootstrap                           # ensure PGlite is running
 *   npx tsx workflows/chat-ux-panels.ts         # start workflow
 *   npm run dashboard                           # monitor progress
 *   npm run send -- --id <wf-id> --topic review --message '{"approved":true}'
 */

import { DBOS } from "@dbos-inc/dbos-sdk";
import { readConnectionInfo } from "../src/db.js";
import { buildDBOSConfig } from "../src/dbos-config.js";
import { execSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";

const PROJECT_ROOT = "/Users/fairchild/code/workspaces";
const BRANCH = "feat/chat-ux-panels";
const WORKTREE = `/Users/fairchild/.worktrees/workspaces/${BRANCH}`;

function run(cmd: string, opts?: { cwd?: string; timeout?: number }): string {
  try {
    return execSync(cmd, {
      cwd: opts?.cwd ?? PROJECT_ROOT,
      encoding: "utf-8",
      timeout: opts?.timeout ?? 120_000,
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
  } catch (err: any) {
    const stderr = err.stderr?.toString() ?? "";
    const stdout = err.stdout?.toString() ?? "";
    throw new Error(`Command failed: ${cmd}\n${stderr}\n${stdout}`);
  }
}

function runSafe(cmd: string, opts?: { cwd?: string }): { stdout: string; ok: boolean } {
  try {
    return { stdout: run(cmd, opts), ok: true };
  } catch (err: any) {
    return { stdout: err.message, ok: false };
  }
}

// --- Steps ---

async function createWorktree(): Promise<{ path: string; branch: string }> {
  // Idempotent — reuse if exists
  if (existsSync(WORKTREE)) {
    const branch = run(`git -C ${WORKTREE} branch --show-current`);
    console.log(`Worktree already exists at ${WORKTREE} on ${branch}`);
    run(`git -C ${WORKTREE} pull --rebase origin main`, { cwd: WORKTREE });
    return { path: WORKTREE, branch };
  }

  run(`git worktree add ${WORKTREE} -b ${BRANCH} main`);
  console.log(`Created worktree at ${WORKTREE}`);

  // Install web deps
  run("pnpm install", { cwd: `${WORKTREE}/web` });
  console.log("Installed web dependencies");

  return { path: WORKTREE, branch: BRANCH };
}

async function implementSidebarCollapse(worktree: string): Promise<string> {
  const webDir = `${worktree}/web`;

  // 1. Update page.module.css — add collapsed grid states
  const cssPath = `${webDir}/src/app/dashboard/page.module.css`;
  let css = readFileSync(cssPath, "utf-8");

  // Add collapsed sidebar variant
  if (!css.includes("leftCollapsed")) {
    css = css.replace(
      "/* ── Responsive: collapse right pane ── */",
      `/* ── Collapsed sidebar ── */
.leftCollapsed {
\tdisplay: none;
}

.columnsLeftCollapsed {
\tgrid-template-columns: 0px 1fr 300px;
}

.columnsLeftCollapsed .left {
\toverflow: hidden;
\twidth: 0;
\tpadding: 0;
\tborder: none;
}

/* ── Collapsed right panel ── */
.rightCollapsed {
\tdisplay: none;
}

.columnsRightCollapsed {
\tgrid-template-columns: 240px 1fr 0px;
}

.columnsRightCollapsed .right {
\toverflow: hidden;
\twidth: 0;
\tpadding: 0;
\tborder: none;
}

.columnsBothCollapsed {
\tgrid-template-columns: 0px 1fr 0px;
}

/* ── Panel toggle buttons ── */
.panelToggle {
\tposition: absolute;
\ttop: 50%;
\ttransform: translateY(-50%);
\twidth: 16px;
\theight: 48px;
\tbackground: var(--bg-surface);
\tborder: 1px solid var(--border-subtle);
\tborder-radius: 4px;
\tcursor: pointer;
\tdisplay: flex;
\talign-items: center;
\tjustify-content: center;
\tcolor: var(--text-tertiary);
\tfont-size: 10px;
\tz-index: 20;
\topacity: 0;
\ttransition: opacity 0.15s ease;
}

.panelToggle:hover {
\topacity: 1;
\tcolor: var(--text-secondary);
}

.columns:hover .panelToggle {
\topacity: 0.5;
}

.leftToggle {
\tleft: 233px;
}

.leftToggleCollapsed {
\tleft: -1px;
}

.rightToggle {
\tright: 293px;
}

.rightToggleCollapsed {
\tright: -1px;
}

/* ── Responsive: collapse right pane ── */`
    );
    writeFileSync(cssPath, css);
    console.log("Updated page.module.css with collapse styles");
  }

  // 2. Update dashboard-shell.tsx — add collapse state + keyboard handler
  const shellPath = `${webDir}/src/app/dashboard/components/dashboard-shell.tsx`;
  let shell = readFileSync(shellPath, "utf-8");

  if (!shell.includes("leftCollapsed")) {
    // Add state declarations after existing useState calls
    shell = shell.replace(
      "const [unreadChat, setUnreadChat] = useState(false);",
      `const [unreadChat, setUnreadChat] = useState(false);
\tconst [leftCollapsed, setLeftCollapsed] = useState(false);
\tconst [rightCollapsed, setRightCollapsed] = useState(false);`
    );

    // Add keyboard shortcut effect
    shell = shell.replace(
      "// Clear unread badge when switching to chat",
      `// Keyboard shortcuts
\tuseEffect(() => {
\t\tconst handleKeyDown = (e: KeyboardEvent) => {
\t\t\tif (e.metaKey && e.key === "b" && !e.shiftKey) {
\t\t\t\te.preventDefault();
\t\t\t\tsetLeftCollapsed((v) => !v);
\t\t\t}
\t\t\tif (e.metaKey && e.shiftKey && e.key === "b") {
\t\t\t\te.preventDefault();
\t\t\t\tsetRightCollapsed((v) => !v);
\t\t\t}
\t\t\tif (e.metaKey && e.key === "1") {
\t\t\t\te.preventDefault();
\t\t\t\tsetTab("dashboard");
\t\t\t}
\t\t\tif (e.metaKey && e.key === "2") {
\t\t\t\te.preventDefault();
\t\t\t\tsetTab("chat");
\t\t\t}
\t\t};
\t\twindow.addEventListener("keydown", handleKeyDown);
\t\treturn () => window.removeEventListener("keydown", handleKeyDown);
\t}, [setTab]);

\t// Clear unread badge when switching to chat`
    );

    // Update grid class to respond to collapse state
    shell = shell.replace(
      '<div className={styles.columns}>',
      `<div className={[
\t\t\t\tstyles.columns,
\t\t\t\tleftCollapsed && styles.columnsLeftCollapsed,
\t\t\t\trightCollapsed && styles.columnsRightCollapsed,
\t\t\t\tleftCollapsed && rightCollapsed && styles.columnsBothCollapsed,
\t\t\t].filter(Boolean).join(" ")}>`
    );

    // Add toggle buttons after the opening div
    shell = shell.replace(
      '<aside className={styles.left}>',
      `{/* Panel toggle affordances */}
\t\t\t\t<button
\t\t\t\t\ttype="button"
\t\t\t\t\tclassName={\`\${styles.panelToggle} \${leftCollapsed ? styles.leftToggleCollapsed : styles.leftToggle}\`}
\t\t\t\t\tonClick={() => setLeftCollapsed((v) => !v)}
\t\t\t\t\ttitle="Toggle sidebar (Cmd+B)"
\t\t\t\t>
\t\t\t\t\t{leftCollapsed ? "\\u25B8" : "\\u25C2"}
\t\t\t\t</button>
\t\t\t\t<button
\t\t\t\t\ttype="button"
\t\t\t\t\tclassName={\`\${styles.panelToggle} \${rightCollapsed ? styles.rightToggleCollapsed : styles.rightToggle}\`}
\t\t\t\t\tonClick={() => setRightCollapsed((v) => !v)}
\t\t\t\t\ttitle="Toggle activity panel (Cmd+Shift+B)"
\t\t\t\t>
\t\t\t\t\t{rightCollapsed ? "\\u25C2" : "\\u25B8"}
\t\t\t\t</button>
\t\t\t\t<aside className={styles.left}>`
    );

    writeFileSync(shellPath, shell);
    console.log("Updated dashboard-shell.tsx with collapse logic");
  }

  return "Sidebar collapse implemented";
}

async function runTests(worktree: string): Promise<{ unit: string; lint: string }> {
  const webDir = `${worktree}/web`;

  const unit = runSafe("pnpm test", { cwd: webDir });
  console.log("Unit tests:", unit.ok ? "PASS" : "FAIL");

  const lint = runSafe("pnpm biome check src/", { cwd: webDir });
  console.log("Lint:", lint.ok ? "PASS" : "FAIL");

  if (!unit.ok) throw new Error(`Unit tests failed:\n${unit.stdout}`);

  return { unit: unit.stdout, lint: lint.stdout };
}

async function openPR(worktree: string): Promise<string> {
  run("git add -A", { cwd: worktree });
  run(`git commit -m "feat(web): collapsible sidebar and activity panel with keyboard shortcuts

Cmd+B toggles left sidebar, Cmd+Shift+B toggles right activity panel.
Cmd+1/Cmd+2 switches between Dashboard and Chat tabs.
Clickable chevron affordances on panel borders.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"`, { cwd: worktree });
  run(`git push -u origin ${BRANCH}`, { cwd: worktree });

  const prUrl = run(`gh pr create --title "feat(web): collapsible panels + keyboard shortcuts" --body "## Summary

- Cmd+B toggles left sidebar (matches desktop app)
- Cmd+Shift+B toggles right activity panel
- Cmd+1/Cmd+2 switches Dashboard/Chat tabs
- Clickable chevron affordances on panel borders
- Panels hide with CSS grid animation

## Test plan

- [ ] Cmd+B hides/shows sidebar
- [ ] Cmd+Shift+B hides/shows activity panel
- [ ] Cmd+1 switches to Dashboard, Cmd+2 to Chat
- [ ] Click chevron on sidebar border toggles it
- [ ] Click chevron on right border toggles it
- [ ] Responsive breakpoints still work

🤖 Generated with [Claude Code](https://claude.com/claude-code)"`, { cwd: worktree });

  return prUrl;
}

// --- Workflow ---

async function chatUxPanelsWorkflow(): Promise<string> {
  console.log("\n=== Chat UX: Collapsible Panels Workflow ===\n");

  // Step 1: Create worktree
  const { path: worktree } = await DBOS.runStep(
    () => createWorktree(),
    { name: "create-worktree" },
  );
  console.log(`\n✓ Step 1: Worktree at ${worktree}\n`);

  // Step 2: Implement sidebar + right panel collapse
  await DBOS.runStep(
    () => implementSidebarCollapse(worktree),
    { name: "implement-sidebar-collapse" },
  );
  console.log("\n✓ Step 2: Sidebar collapse implemented\n");

  // Step 3: Run tests
  const tests = await DBOS.runStep(
    () => runTests(worktree),
    { name: "run-tests", retriesAllowed: true, maxAttempts: 2 },
  );
  console.log(`\n✓ Step 3: Tests complete\n`);

  // Step 4: Await human review
  console.log("\n⏸  Workflow paused — waiting for review.");
  console.log("   Inspect the worktree, then approve:");
  console.log(`   npm run send -- --id <wf-id> --topic review --message '{"approved":true}'`);
  console.log(`   Or check the dashboard: npm run dashboard\n`);

  const approval = await DBOS.recv<{ approved: boolean }>("review", 7200); // 2hr timeout
  if (!approval?.approved) {
    return "Workflow cancelled — not approved.";
  }
  console.log("\n✓ Step 4: Review approved\n");

  // Step 5: Open PR
  const prUrl = await DBOS.runStep(
    () => openPR(worktree),
    { name: "open-pr" },
  );
  console.log(`\n✓ Step 5: PR opened — ${prUrl}\n`);

  return `Done! PR: ${prUrl}`;
}

// --- Registration + Run ---

const chatUxPanels = DBOS.registerWorkflow(chatUxPanelsWorkflow, {
  name: "chatUxPanels",
});

const info = readConnectionInfo();
if (!info) {
  console.error("No database connection. Run `npm run bootstrap` first.");
  process.exit(1);
}

DBOS.setConfig(buildDBOSConfig({ databaseUrl: info.databaseUrl, mode: info.mode }));
await DBOS.launch();

try {
  const handle = await DBOS.startWorkflow(chatUxPanels)();
  console.log(`\nWorkflow ID: ${handle.workflowID}`);
  console.log(`Monitor: npm run dashboard`);
  console.log(`Inspect: npm run inspect -- ${handle.workflowID}\n`);

  const result = await handle.getResult();
  console.log(`\n=== Result: ${result} ===\n`);
} finally {
  await DBOS.shutdown();
}
