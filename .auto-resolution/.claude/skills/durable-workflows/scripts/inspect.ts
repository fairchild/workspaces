/**
 * Inspect a workflow's step-by-step execution trace.
 *
 * Usage: npx tsx scripts/inspect.ts <workflow-id>
 */

import { createClient } from "../src/client.js";

async function main() {
  const workflowId = process.argv[2];
  if (!workflowId) {
    console.error("Usage: inspect.ts <workflow-id>");
    process.exit(1);
  }

  const client = await createClient();

  try {
    // Get workflow status
    const wf = await client.getWorkflow(workflowId);
    if (!wf) {
      console.error(`Workflow ${workflowId} not found.`);
      process.exit(1);
    }

    console.log(`\nWorkflow: ${wf.workflowName ?? "unknown"}`);
    console.log(`ID: ${wf.workflowID}`);
    console.log(`Status: ${wf.status}`);
    if (wf.createdAt) console.log(`Created: ${new Date(Number(wf.createdAt)).toISOString()}`);
    if (wf.updatedAt) console.log(`Updated: ${new Date(Number(wf.updatedAt)).toISOString()}`);

    // Get steps
    const steps = await client.listWorkflowSteps(workflowId);

    if (steps.length === 0) {
      console.log("\nNo steps recorded yet.");
      return;
    }

    console.log(`\nSteps (${steps.length}):`);
    console.log("─".repeat(60));

    for (const step of steps) {
      const duration =
        step.startedAtEpochMs && step.completedAtEpochMs
          ? `${step.completedAtEpochMs - step.startedAtEpochMs}ms`
          : "—";

      console.log(`  #${step.functionID} ${step.name}`);

      if (step.output !== undefined && step.output !== null) {
        const outputStr = JSON.stringify(step.output);
        console.log(
          `     Output: ${outputStr.length > 200 ? outputStr.substring(0, 200) + "…" : outputStr}`,
        );
      }

      if (step.error) {
        console.log(`     Error: ${step.error}`);
      }

      if (step.childWorkflowID) {
        console.log(`     Child workflow: ${step.childWorkflowID}`);
      }

      console.log(`     Duration: ${duration}`);
    }

    console.log("");
  } finally {
    await client.destroy();
  }
}

main().catch((err) => {
  console.error("Inspect error:", err.message);
  process.exit(1);
});
