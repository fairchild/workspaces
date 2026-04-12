/**
 * Fork a workflow from a specific step.
 *
 * Usage: npx tsx scripts/fork.ts <workflow-id> <start-step>
 */

import { createClient } from "../src/client.js";

async function main() {
  const workflowId = process.argv[2];
  const startStep = parseInt(process.argv[3] ?? "");

  if (!workflowId || isNaN(startStep)) {
    console.error("Usage: fork.ts <workflow-id> <start-step>");
    console.error("  start-step: step number to fork from (0-based)");
    process.exit(1);
  }

  const client = await createClient();

  try {
    const newId = await client.forkWorkflow(workflowId, startStep);
    console.log(`✓ Forked workflow`);
    console.log(`  Original: ${workflowId}`);
    console.log(`  New:      ${newId}`);
    console.log(`  From step: ${startStep}`);
  } finally {
    await client.destroy();
  }
}

main().catch((err) => {
  console.error("Fork error:", err.message);
  process.exit(1);
});
