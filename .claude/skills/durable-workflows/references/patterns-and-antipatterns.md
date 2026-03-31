# Patterns and Anti-Patterns

## The Determinism Rule

**Workflow functions must be deterministic.** All I/O, randomness, timestamps,
and external calls go in steps. The workflow body is replayed on recovery —
non-deterministic code produces different results on replay, breaking recovery.

### Anti-patterns (never do in a workflow body)

```typescript
// ❌ Timestamps change on replay
const now = Date.now();

// ❌ Random values change on replay
const id = Math.random().toString(36);
const uuid = crypto.randomUUID();

// ❌ Direct I/O in workflow body
const data = await fetch("https://api.example.com");
const file = await fs.readFile("data.json");

// ❌ Environment reads (may change between runs)
const key = process.env.API_KEY;
```

### Correct patterns (wrap in steps)

```typescript
// ✅ Timestamp via step
const now = await DBOS.runStep(
  async () => Date.now(),
  { name: "timestamp" }
);

// ✅ ID generation via step
const id = await DBOS.runStep(
  async () => crypto.randomUUID(),
  { name: "generate-id" }
);

// ✅ I/O via step
const data = await DBOS.runStep(
  async () => (await fetch("https://api.example.com")).json(),
  { name: "fetch-api" }
);

// ✅ Env reads via step
const key = await DBOS.runStep(
  async () => process.env.API_KEY!,
  { name: "read-config" }
);
```

## Common Patterns

### Retry with backoff

```typescript
const result = await DBOS.runStep(
  () => callFlakiAPI(),
  {
    name: "call-api",
    retriesAllowed: true,
    maxAttempts: 5,
    intervalSeconds: 1,
    backoffRate: 2, // 1s, 2s, 4s, 8s, 16s
  }
);
```

### Idempotent workflows

```typescript
// Same workflowID = same execution (exactly-once)
const handle = await DBOS.startWorkflow(processPayment, {
  workflowID: `payment-${orderId}`,
})(orderId, amount);
```

### Child workflows

```typescript
async function parentWorkflow() {
  // Start child and await
  const child = await DBOS.startWorkflow(childWorkflow)("input");
  return await child.getResult();
}
```

### Progress tracking via events

```typescript
// In workflow
await DBOS.setEvent("progress", { step: 3, total: 5 });

// From outside
const progress = await DBOS.getEvent(workflowId, "progress");
```

### Conditional branching (safe)

```typescript
async function conditionalWorkflow(input: string) {
  // Conditional logic is fine — it's deterministic based on step outputs
  const data = await DBOS.runStep(() => fetchData(input), { name: "fetch" });

  if (data.needsApproval) {
    const approval = await DBOS.recv("approval", 3600);
    if (!approval) return "timed out";
  }

  return await DBOS.runStep(() => process(data), { name: "process" });
}
```

## Registration Timing

Workflows MUST be registered before `DBOS.launch()`. On launch, DBOS scans
for PENDING workflows and restarts them — if the function isn't registered,
recovery fails silently.

```typescript
// ✅ Register first, launch second
const wf = DBOS.registerWorkflow(myFn, { name: "myFn" });
await DBOS.launch();

// ❌ Registering after launch — recovered workflows may be lost
await DBOS.launch();
const wf = DBOS.registerWorkflow(myFn, { name: "myFn" }); // too late!
```
