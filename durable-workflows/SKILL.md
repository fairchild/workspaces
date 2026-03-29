---
name: durable-workflows
description: >
  Orchestrate durable workflows with crash recovery, exactly-once execution,
  and observable state using DBOS and embedded Postgres (PGlite). Use when
  building multi-step processes, AI agent tool chains, data pipelines, or
  any long-running task that needs to survive interruptions. Also use when
  the user mentions "durable", "workflow", "checkpoint", "resume",
  "crash recovery", "exactly-once", "orchestrate", or "background task".
---

# Durable Workflows

Build multi-step processes that survive crashes, restarts, and interruptions.
Each step is checkpointed to Postgres — on recovery, completed steps are
skipped and execution resumes from where it left off.

## Quick Start

```bash
# 1. Install (from skill directory)
cd ~/.claude/skills/durable-workflows && npm install

# 2. Bootstrap embedded Postgres
npx tsx scripts/bootstrap.ts

# 3. Write a workflow (copy a template)
cp templates/basic-workflow.ts my-workflow.ts
```

## Core Concepts

**Workflows** are deterministic functions. All I/O goes in **steps**.

```typescript
import { DBOS } from "@dbos-inc/dbos-sdk";

async function myWorkflow(input: string): Promise<string> {
  // Steps are checkpointed — won't re-run on recovery
  const data = await DBOS.runStep(
    () => fetch(input).then(r => r.text()),
    { name: "fetch" }
  );
  const result = await DBOS.runStep(
    () => processData(data),
    { name: "process" }
  );
  return result;
}

// Register BEFORE DBOS.launch()
const wf = DBOS.registerWorkflow(myWorkflow, { name: "myWorkflow" });
```

**The determinism rule**: Never put `Date.now()`, `Math.random()`, `fetch()`,
file I/O, or env reads directly in a workflow body. Wrap them in
`DBOS.runStep()`. See `references/patterns-and-antipatterns.md`.

## The Orchestrator Pattern

The main session acts as orchestrator — starts workflows, monitors progress,
sends messages to unblock waiting workflows.

```typescript
// Start workflows
const analysis = await DBOS.startWorkflow(analyzeCode)("/repo");
const tests = await DBOS.startWorkflow(runTests)("unit");

// Monitor
const pending = await DBOS.listWorkflows({ status: "PENDING" });

// Unblock (workflow is waiting on DBOS.recv("approval"))
await DBOS.send(analysis.workflowID, { approved: true }, "approval");

// Collect results
const result = await analysis.getResult();
```

See `templates/orchestrator-pattern.ts` for the full example.

## CLI Tools

All tools connect to PGlite via `.dbos/connection.json` or `DBOS_DATABASE_URL`.

| Command | Purpose |
|---------|---------|
| `npm run bootstrap` | Start PGlite + DBOS (idempotent) |
| `npm run dashboard` | Workflow overview table |
| `npm run dashboard -- --json` | JSON output |
| `npm run send -- --id <id> --topic <t> --message '<json>'` | Send message to workflow |
| `npm run inspect -- <id>` | Step-by-step trace |
| `npm run fork -- <id> <step>` | Fork workflow from step |
| `npm run list -- [--status=X]` | JSON workflow list |
| `npm run shutdown` | Stop PGlite |

## Messaging & Human-in-the-Loop

Workflows can wait for external input:

```typescript
// In workflow — blocks until message arrives or timeout
const msg = await DBOS.recv<{ approved: boolean }>("approval", 3600);

// From orchestrator or CLI
await DBOS.send(workflowId, { approved: true }, "approval");
```

The dashboard shows which workflows are waiting and on what topic.
See `templates/human-in-the-loop.ts`.

## Configuration

- **Embedded mode** (default): PGlite at `.dbos/pgdata/`, auto-port
- **External Postgres**: Set `DBOS_DATABASE_URL=postgresql://...`

Code works unchanged between modes — PGlite is real Postgres.

## Templates

| Template | Use When |
|----------|----------|
| `basic-workflow.ts` | Simple multi-step process |
| `agent-workflow.ts` | LLM agent with tool calls |
| `orchestrator-pattern.ts` | Main session dispatching sub-workflows |
| `human-in-the-loop.ts` | Workflow needs approval/input |
| `queue-parallel.ts` | Fan-out with concurrency limits |

## Anti-Patterns

See `references/patterns-and-antipatterns.md` for common mistakes and
`references/troubleshooting.md` for debugging.

Key rules:
1. Register workflows before `DBOS.launch()`
2. All I/O in steps, never in workflow body
3. For PGlite: pool size **must** be 1 (pool>=2 deadlocks), LISTEN/NOTIFY **must** be off
4. Set socket server `maxConnections: 20` (default=1 causes ECONNRESET)
5. Step outputs up to 1MB work fine — store larger data externally
