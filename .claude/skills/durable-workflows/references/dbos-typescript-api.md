# DBOS TypeScript API Reference (Condensed)

## Configuration

```typescript
import { DBOS, DBOSClient, WorkflowQueue } from "@dbos-inc/dbos-sdk";

DBOS.setConfig({
  systemDatabaseUrl: "postgresql://...",
  systemDatabasePoolSize: 1,    // Use 1 for PGlite
  useListenNotify: false,        // Disable for PGlite
  runAdminServer: false,
  logLevel: "info",
});
```

## Registration (MUST happen before DBOS.launch)

```typescript
// Register a workflow
const myWorkflow = DBOS.registerWorkflow(myWorkflowFn, {
  name: "myWorkflow",
  maxRecoveryAttempts: 5,  // optional
});

// Register a named step (optional — DBOS.runStep works with anonymous fns)
const myStep = DBOS.registerStep(myStepFn, {
  name: "myStep",
  retriesAllowed: true,
  maxAttempts: 3,
  intervalSeconds: 1,
  backoffRate: 2,
});
```

## Lifecycle

```typescript
await DBOS.launch();     // Initialize DB, recover PENDING workflows
await DBOS.shutdown();   // Graceful shutdown
```

## Running Workflows

```typescript
// Start and await
const handle = await DBOS.startWorkflow(myWorkflow, {
  workflowID: "custom-id",  // optional, for idempotency
  queueName: "myQueue",     // optional, for rate limiting
  timeoutMS: 30000,          // optional
})(arg1, arg2);

const result = await handle.getResult();
const status = await handle.getStatus();
```

## Inside Workflows (deterministic context)

```typescript
async function myWorkflowFn(input: string): Promise<string> {
  // Run a step (all I/O must go here)
  const data = await DBOS.runStep(
    () => fetchFromAPI(input),
    { name: "fetch", retriesAllowed: true, maxAttempts: 3 }
  );

  // Durable sleep (survives restarts)
  await DBOS.sleep(5000);

  // Wait for external message
  const msg = await DBOS.recv<string>("topic", 60); // 60s timeout

  // Set event (observable from outside)
  await DBOS.setEvent("progress", "50%");

  return data;
}
```

## Messaging

```typescript
// Send to a workflow (from anywhere)
await DBOS.send(workflowId, message, "topic");

// Receive in a workflow
const msg = await DBOS.recv<T>("topic", timeoutSeconds);
```

## Management (in-process)

```typescript
const workflows = await DBOS.listWorkflows({
  status: "PENDING",         // PENDING, SUCCESS, ERROR, CANCELLED, ENQUEUED
  workflowName: "myWorkflow",
  limit: 50,
  sortDesc: true,
});

const steps = await DBOS.listWorkflowSteps(workflowId);
// StepInfo: { functionID, name, output, error, childWorkflowID, startedAtEpochMs, completedAtEpochMs }
```

## DBOSClient (out-of-band, for CLI tools)

```typescript
const client = await DBOSClient.create({
  systemDatabaseUrl: "postgresql://...",
});

await client.listWorkflows({ status: "PENDING" });
await client.listWorkflowSteps(workflowId);
await client.getWorkflow(workflowId);
await client.send(workflowId, message, "topic");
await client.cancelWorkflow(workflowId);
await client.forkWorkflow(workflowId, startStep);
await client.destroy();
```

## WorkflowQueue

```typescript
const queue = new WorkflowQueue("myQueue", {
  concurrency: 5,          // Max concurrent globally
  workerConcurrency: 2,   // Max per DBOS process
  rateLimit: { limitPerPeriod: 10, periodSec: 60 },
});

// Pass as listenQueues in config
DBOS.setConfig({ listenQueues: [queue] });

// Start workflow on queue
await DBOS.startWorkflow(myWorkflow, { queueName: "myQueue" })(args);
```
