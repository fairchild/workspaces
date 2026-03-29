/**
 * Basic three-step workflow.
 *
 * Demonstrates the fundamental pattern:
 * 1. All I/O goes in steps (DBOS.runStep)
 * 2. Workflow body is deterministic (no Date.now, Math.random, fetch, etc.)
 * 3. Steps are checkpointed — on crash recovery, completed steps are skipped
 *
 * Copy this file and modify for your use case.
 */

import { DBOS } from "@dbos-inc/dbos-sdk";

// --- Steps: all side effects go here ---

async function fetchData(url: string): Promise<string> {
  const res = await fetch(url);
  return await res.text();
}

async function processData(raw: string): Promise<Record<string, unknown>> {
  // Simulate processing
  return { length: raw.length, preview: raw.substring(0, 100) };
}

async function saveResult(data: Record<string, unknown>): Promise<string> {
  // Simulate saving to storage
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
