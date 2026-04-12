/**
 * Human-in-the-loop workflow.
 *
 * Does work, then waits for approval before proceeding.
 * The orchestrator (or CLI) sends the approval via DBOS.send().
 */

import { DBOS } from "@dbos-inc/dbos-sdk";

// --- Types ---

interface ApprovalMessage {
  approved: boolean;
  reviewer: string;
  notes?: string;
}

// --- Steps ---

async function prepareChanges(): Promise<string[]> {
  return ["migration.sql", "schema-update.ts", "seed-data.json"];
}

async function applyChanges(files: string[]): Promise<string> {
  console.log(`Applying ${files.length} changes...`);
  return `Applied: ${files.join(", ")}`;
}

async function rollbackChanges(): Promise<void> {
  console.log("Rolling back changes...");
}

// --- Workflow ---

async function deployWithApprovalWorkflow(
  environment: string,
): Promise<string> {
  // Step 1: Prepare
  const changes = await DBOS.runStep(prepareChanges, { name: "prepare" });
  console.log(`Prepared ${changes.length} changes for ${environment}`);

  // Step 2: Wait for human approval (timeout: 1 hour)
  // The orchestrator sends: DBOS.send(workflowId, { approved: true, reviewer: "alice" }, "approval")
  // Or via CLI: npx tsx scripts/send.ts --id <id> --topic approval --message '{"approved":true,"reviewer":"alice"}'
  const approval = await DBOS.recv<ApprovalMessage>("approval", 3600);

  if (!approval) {
    await DBOS.runStep(rollbackChanges, { name: "rollback-timeout" });
    return `Deploy to ${environment} timed out waiting for approval.`;
  }

  if (!approval.approved) {
    await DBOS.runStep(rollbackChanges, { name: "rollback-rejected" });
    return `Deploy to ${environment} rejected by ${approval.reviewer}.${approval.notes ? ` Notes: ${approval.notes}` : ""}`;
  }

  // Step 3: Apply (only if approved)
  const result = await DBOS.runStep(
    () => applyChanges(changes),
    { name: "apply" },
  );

  return `Deploy to ${environment} approved by ${approval.reviewer}. ${result}`;
}

// --- Registration ---

export const deployWithApproval = DBOS.registerWorkflow(
  deployWithApprovalWorkflow,
  { name: "deployWithApproval" },
);
