/**
 * Meta-workflow: orchestrate building the web dashboard.
 *
 * Each plan task is a step that waits for a completion signal via DBOS.recv().
 * The orchestrating agent dispatches subagents for each task, then sends
 * a "task-done" message when the subagent finishes.
 *
 * Usage:
 *   npx tsx workflows/build-dashboard.ts          # start the workflow
 *   npm run send -- --id <wf-id> --topic task-done --message '{"task":0}'
 *   npm run dashboard                             # watch progress
 */

import { DBOS } from "@dbos-inc/dbos-sdk";
import { readConnectionInfo } from "../src/db.js";
import { buildDBOSConfig } from "../src/dbos-config.js";

const TASKS = [
  "Add httpPort to ConnectionInfo",
  "Create HTTP server module",
  "Wire HTTP server into bootstrap",
  "Create dashboard HTML",
  "Update CLI dashboard to print URL",
  "Integration test",
];

async function announceTask(index: number): Promise<{ task: string; index: number }> {
  console.log(`\n→ Task ${index}: ${TASKS[index]}`);
  return { task: TASKS[index], index };
}

async function recordCompletion(index: number, signal: unknown): Promise<{ task: string; done: true }> {
  console.log(`✓ Task ${index} complete: ${TASKS[index]}`);
  return { task: TASKS[index], done: true };
}

async function buildDashboardWorkflow(): Promise<string> {
  for (let i = 0; i < TASKS.length; i++) {
    // Announce which task we're waiting on
    await DBOS.runStep(() => announceTask(i), { name: `announce-${i}` });

    // Wait for completion signal (1 hour timeout per task)
    const signal = await DBOS.recv<{ task: number }>("task-done", 3600);
    if (!signal) {
      throw new Error(`Task ${i} ("${TASKS[i]}") timed out waiting for completion signal`);
    }

    // Record completion
    await DBOS.runStep(() => recordCompletion(i, signal), { name: `complete-${i}` });
  }

  return `All ${TASKS.length} tasks complete — dashboard built!`;
}

// --- Registration ---
export const buildDashboard = DBOS.registerWorkflow(buildDashboardWorkflow, {
  name: "buildDashboard",
});

// --- Run ---
const info = readConnectionInfo();
if (!info) {
  console.error("No database connection. Run `npm run bootstrap` first.");
  process.exit(1);
}

DBOS.setConfig(buildDBOSConfig({ databaseUrl: info.databaseUrl, mode: info.mode }));
await DBOS.launch();

const handle = await DBOS.startWorkflow(buildDashboard)();
console.log(`\nWorkflow started: ${handle.workflowID}`);
console.log(`Monitor: npm run dashboard`);
console.log(`\nWaiting for task signals... (send: npm run send -- --id ${handle.workflowID} --topic task-done --message '{"task":0}')\n`);

// Keep alive — the workflow is waiting for recv() signals
const result = await handle.getResult();
console.log(`\n${result}`);
await DBOS.shutdown();
