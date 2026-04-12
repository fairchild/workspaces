/**
 * Basic three-step workflow.
 *
 * Runnable standalone: `npx tsx templates/basic-workflow.ts`
 * (requires `npm run bootstrap` running in another terminal)
 *
 * Copy this file and modify the workflow body and steps for your use case.
 * The init/run section at the bottom connects to the running PGlite instance.
 */

import { DBOS } from "@dbos-inc/dbos-sdk";
import { readConnectionInfo } from "../src/db.js";
import { buildDBOSConfig } from "../src/dbos-config.js";

// --- Steps: all side effects go here ---

async function fetchData(url: string): Promise<string> {
  const res = await fetch(url);
  return await res.text();
}

async function processData(raw: string): Promise<Record<string, unknown>> {
  return { length: raw.length, preview: raw.substring(0, 100) };
}

async function saveResult(data: Record<string, unknown>): Promise<string> {
  const id = crypto.randomUUID();
  console.log(`Saved result ${id}:`, data);
  return id;
}

// --- Workflow: deterministic orchestration ---

async function dataProcessingWorkflow(url: string): Promise<string> {
  // Step 1: Fetch (checkpointed — won't re-fetch on recovery)
  const raw = await DBOS.runStep(
    () => fetchData(url),
    { name: "fetch", retriesAllowed: true, maxAttempts: 3 },
  );

  // Step 2: Process
  const processed = await DBOS.runStep(
    () => processData(raw),
    { name: "process" },
  );

  // Step 3: Save
  const resultId = await DBOS.runStep(
    () => saveResult(processed),
    { name: "save" },
  );

  return resultId;
}

// --- Registration (must happen before DBOS.launch) ---

export const dataProcessing = DBOS.registerWorkflow(dataProcessingWorkflow, {
  name: "dataProcessing",
});

// --- Run (when executed directly) ---

const info = readConnectionInfo();
if (!info) {
  console.error("No database connection. Run `npm run bootstrap` first.");
  process.exit(1);
}

DBOS.setConfig(buildDBOSConfig({ databaseUrl: info.databaseUrl, mode: info.mode }));
await DBOS.launch();

try {
  const handle = await DBOS.startWorkflow(dataProcessing)("https://example.com");
  console.log(`Started workflow ${handle.workflowID}`);
  const result = await handle.getResult();
  console.log(`Result: ${result}`);
} finally {
  await DBOS.shutdown();
}
