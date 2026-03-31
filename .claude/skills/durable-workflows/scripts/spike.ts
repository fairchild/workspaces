/**
 * Phase 1 Spike: Validate PGlite ↔ DBOS Compatibility
 *
 * Tests:
 * 1. PGlite starts with filesystem persistence
 * 2. PGliteSocketServer exposes it over TCP
 * 3. DBOS connects and creates system tables
 * 4. A 3-step workflow runs to completion
 * 5. send/recv messaging works
 * 6. Workflow and step listing works
 * 7. DBOSClient out-of-band management works
 */

import { PGlite } from "@electric-sql/pglite";
import { uuid_ossp } from "@electric-sql/pglite/contrib/uuid_ossp";
import { PGLiteSocketServer } from "@electric-sql/pglite-socket";
import { DBOS, DBOSClient } from "@dbos-inc/dbos-sdk";
import { mkdirSync, rmSync } from "node:fs";
import { resolve } from "node:path";

const DATA_DIR = resolve(import.meta.dirname, "../.spike-data/pgdata");
const LOG_PREFIX = "[spike]";

function log(msg: string) {
  console.log(`${LOG_PREFIX} ${msg}`);
}

// --- Step functions ---

async function stepFetch(): Promise<string> {
  log("  step 1: fetch data");
  return "raw-data-from-api";
}

async function stepProcess(data: string): Promise<string> {
  log(`  step 2: process "${data}"`);
  return data.toUpperCase();
}

async function stepSave(data: string): Promise<string> {
  log(`  step 3: save "${data}"`);
  return `saved:${data}`;
}

// --- Workflow functions ---

async function threeStepWorkflow(): Promise<string> {
  const raw = await DBOS.runStep(stepFetch, { name: "fetch" });
  const processed = await DBOS.runStep(() => stepProcess(raw), {
    name: "process",
  });
  const result = await DBOS.runStep(() => stepSave(processed), {
    name: "save",
  });
  return result;
}

async function messagingWorkflow(): Promise<string> {
  log("  messaging wf: waiting for message on topic 'input'...");
  const msg = await DBOS.recv<string>("input", 30);
  if (msg === null) {
    return "TIMEOUT";
  }
  log(`  messaging wf: received "${msg}"`);
  const result = await DBOS.runStep(
    async () => `processed:${msg}`,
    { name: "process-message" },
  );
  return result;
}

async function main() {
  // Clean slate for spike
  rmSync(resolve(import.meta.dirname, "../.spike-data"), {
    recursive: true,
    force: true,
  });
  mkdirSync(DATA_DIR, { recursive: true });

  // 1. Start PGlite with uuid-ossp extension (required by DBOS)
  log("Starting PGlite...");
  const startTime = Date.now();
  const db = await PGlite.create(DATA_DIR, {
    extensions: { uuid_ossp },
  });
  log(`PGlite ready in ${Date.now() - startTime}ms`);

  // 2. Start socket server on random port
  log("Starting PGlite socket server...");
  const server = new PGLiteSocketServer({
    db,
    port: 0,
    host: "127.0.0.1",
  });

  await server.start();
  const conn = server.getServerConn();
  log(`Socket server listening on ${conn}`);

  const databaseUrl = `postgresql://postgres:postgres@${conn}/postgres`;
  log(`Database URL: ${databaseUrl}`);

  try {
    // 3. Configure and launch DBOS
    log("Configuring DBOS...");
    DBOS.setConfig({
      systemDatabaseUrl: databaseUrl,
      systemDatabasePoolSize: 1, // PGlite is single-connection; multiplexer serializes
      useListenNotify: false, // PGlite socket doesn't support LISTEN/NOTIFY reliably
      runAdminServer: false, // Don't need admin server for spike
      logLevel: "warn",
    });

    // Register workflows before launch (required for recovery)
    const registeredThreeStep = DBOS.registerWorkflow(threeStepWorkflow, {
      name: "threeStepWorkflow",
    });
    const registeredMessaging = DBOS.registerWorkflow(messagingWorkflow, {
      name: "messagingWorkflow",
    });

    log("Launching DBOS...");
    const dbosStartTime = Date.now();
    await DBOS.launch();
    log(`DBOS launched in ${Date.now() - dbosStartTime}ms`);

    // 4. Run the 3-step workflow
    log("\n=== Test 1: Three-step workflow ===");
    const handle = await DBOS.startWorkflow(registeredThreeStep)();
    const threeStepWfId = handle.workflowID;
    const result = await handle.getResult();
    log(`Workflow result: ${result}`);

    if (result !== "saved:RAW-DATA-FROM-API") {
      throw new Error(`Unexpected result: ${result}`);
    }
    log("✓ Three-step workflow passed!");

    // 5. Test send/recv messaging
    log("\n=== Test 2: Send/Recv messaging ===");
    const msgHandle = await DBOS.startWorkflow(registeredMessaging)();
    const wfId = msgHandle.workflowID;
    log(`Started messaging workflow: ${wfId}`);

    // Small delay to let the workflow reach recv()
    await new Promise((r) => setTimeout(r, 500));

    // Send a message
    log("Sending message...");
    await DBOS.send(wfId, "hello-from-orchestrator", "input");

    const msgResult = await msgHandle.getResult();
    log(`Messaging workflow result: ${msgResult}`);

    if (msgResult !== "processed:hello-from-orchestrator") {
      throw new Error(`Unexpected messaging result: ${msgResult}`);
    }
    log("✓ Send/Recv messaging passed!");

    // 6. Test listing workflows
    log("\n=== Test 3: List workflows ===");
    const workflows = await DBOS.listWorkflows({
      status: "SUCCESS",
    });
    log(`Found ${workflows.length} successful workflows`);
    for (const wf of workflows) {
      log(
        `  - ${wf.workflowID.substring(0, 8)}.. ${wf.workflowName} [${wf.status}]`,
      );
    }

    // 7. Test listing steps (StepInfo has: functionID, name, output, error)
    log("\n=== Test 4: List workflow steps ===");
    const steps = await DBOS.listWorkflowSteps(handle.workflowID);
    log(`Steps for three-step workflow:`);
    for (const step of steps) {
      log(
        `  - #${step.functionID}: ${step.name} output=${JSON.stringify(step.output)} error=${step.error}`,
      );
    }

    if (steps.length !== 3) {
      throw new Error(`Expected 3 steps, got ${steps.length}`);
    }
    log("✓ Workflow step listing passed!");

    log("✓ Tests 1-4 passed, shutting down DBOS for client test...");
    await DBOS.shutdown();

    // Allow PGlite socket server to clean up stale connections
    await new Promise((r) => setTimeout(r, 1000));

    // 8. Test DBOSClient (out-of-band management — the CLI tool pattern)
    // DBOSClient connects independently, like dashboard.ts/send.ts would
    log("\n=== Test 5: DBOSClient (management) ===");
    const client = await DBOSClient.create({
      systemDatabaseUrl: databaseUrl,
    });

    const clientWorkflows = await client.listWorkflows({});
    log(`DBOSClient found ${clientWorkflows.length} total workflows`);

    const clientSteps = await client.listWorkflowSteps(threeStepWfId);
    log(`DBOSClient found ${clientSteps.length} steps for three-step workflow`);

    await client.destroy();
    log("✓ DBOSClient management passed!");

    log("\n========================================");
    log("ALL SPIKE TESTS PASSED!");
    log("PGlite ↔ DBOS compatibility: CONFIRMED");
    log("========================================\n");
  } finally {
    log("Shutting down...");
    try { await DBOS.shutdown(); } catch {}
    await server.stop();
    await db.close();
    log("Done.");
  }
}

main().catch((err) => {
  console.error("Spike failed:", err);
  process.exit(1);
});
