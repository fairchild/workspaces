/**
 * Fan-out pattern with durable queues.
 *
 * Enqueues tasks with concurrency limits, then collects results.
 * Uses WorkflowQueue for Postgres-backed rate limiting.
 */

import { DBOS, WorkflowQueue } from "@dbos-inc/dbos-sdk";

// Queue with concurrency limit of 3
const processingQueue = new WorkflowQueue("processing", {
  concurrency: 3,
});

// --- Steps ---

async function processItem(item: string): Promise<string> {
  // Simulate work with varying duration
  const ms = 100 + Math.random() * 400;
  await new Promise((r) => setTimeout(r, ms));
  return `${item}:processed`;
}

// --- Worker workflow (runs per-item) ---

async function processItemWorkflow(item: string): Promise<string> {
  const result = await DBOS.runStep(
    () => processItem(item),
    { name: `process-${item}`, retriesAllowed: true, maxAttempts: 3 },
  );
  return result;
}

const processItemWf = DBOS.registerWorkflow(processItemWorkflow, {
  name: "processItem",
});

// --- Fan-out orchestrator ---

async function fanOutWorkflow(items: string[]): Promise<string[]> {
  // Start all items on the queue (concurrency is enforced by the queue)
  const handles = [];
  for (const item of items) {
    const handle = await DBOS.startWorkflow(processItemWf, {
      queueName: "processing",
    })(item);
    handles.push(handle);
  }

  // Collect all results
  const results: string[] = [];
  for (const handle of handles) {
    results.push(await handle.getResult());
  }

  return results;
}

export const fanOut = DBOS.registerWorkflow(fanOutWorkflow, {
  name: "fanOut",
});
