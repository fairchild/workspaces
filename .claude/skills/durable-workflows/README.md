# Durable Workflows

Multi-step processes that survive crashes. Each step checkpoints to Postgres — on
recovery, completed steps skip and execution resumes where it left off.

Built on [DBOS](https://docs.dbos.dev/) for workflow orchestration and
[PGlite](https://pglite.dev/) for zero-dependency embedded Postgres (real
Postgres compiled to WASM).

## Why

Long-running tasks fail. API calls timeout, processes get killed, machines restart.
Without durability, you retry from scratch or build ad-hoc checkpointing.

This skill gives you:

- **Crash recovery** — restart the process and it picks up where it left off
- **Exactly-once steps** — a step that completed won't run again, even after a crash
- **Observable state** — dashboard, step inspection, workflow listing via CLI
- **Messaging** — send data to a waiting workflow (human-in-the-loop, approvals)
- **Zero infrastructure** — embedded Postgres, no external services needed
- **Escape hatch** — swap PGlite for real Postgres with one env var change

## Setup

```bash
cd ~/.claude/skills/durable-workflows
npm install
```

Or from this repo:

```bash
./install.sh   # copies to ~/.claude/skills/ and runs npm install
```

## Usage

**Terminal 1** — start the embedded database:

```bash
npm run bootstrap
```

This starts PGlite, exposes it on a local socket, initializes DBOS system tables,
and writes `.dbos/connection.json` for other processes to find. Runs until you
Ctrl+C or `npm run shutdown` from another terminal.

**Terminal 2** — run a workflow:

```bash
npx tsx templates/basic-workflow.ts
```

Or copy the template and modify it:

```bash
cp templates/basic-workflow.ts my-workflow.ts
# edit my-workflow.ts
npx tsx my-workflow.ts
```

**Monitor and interact:**

```bash
npm run dashboard                # workflow overview table
npm run inspect -- <workflow-id> # step-by-step trace
npm run list                     # JSON listing (filterable: --status=PENDING)
npm run send -- --id <id> --topic approval --message '{"approved":true}'
npm run shutdown                 # stop PGlite
```

## Writing Workflows

A workflow is a function where all side effects go in steps:

```typescript
import { DBOS } from "@dbos-inc/dbos-sdk";

async function myWorkflow(input: string): Promise<string> {
  const data = await DBOS.runStep(
    () => fetch(input).then(r => r.text()),
    { name: "fetch" }
  );

  const result = await DBOS.runStep(
    () => transform(data),
    { name: "transform" }
  );

  return result;
}

const wf = DBOS.registerWorkflow(myWorkflow, { name: "myWorkflow" });
```

**The rule**: never put `fetch()`, `Date.now()`, `Math.random()`, file I/O, or env
reads directly in the workflow body. Wrap them in `DBOS.runStep()`. The workflow body
must be deterministic so recovery can replay it.

### Messaging

Workflows can pause and wait for external input:

```typescript
// Inside a workflow — blocks until message arrives (timeout: 1 hour)
const approval = await DBOS.recv<{ ok: boolean }>("approval", 3600);

// From another process or the CLI
await DBOS.send(workflowId, { ok: true }, "approval");
```

### Queues

Fan out work with concurrency limits:

```typescript
const queue = new WorkflowQueue("processing", { concurrency: 3 });

// Enqueue 100 items — only 3 run at a time
for (const item of items) {
  await DBOS.startWorkflow(processItem, { queueName: "processing" })(item);
}
```

## Templates

| File | Pattern |
|------|---------|
| `basic-workflow.ts` | Fetch, process, save — runnable standalone |
| `agent-workflow.ts` | LLM agent loop with checkpointed tool calls |
| `orchestrator-pattern.ts` | Main session dispatching sub-workflows |
| `human-in-the-loop.ts` | Workflow pauses for approval before proceeding |
| `queue-parallel.ts` | Fan-out with Postgres-backed concurrency limits |

`basic-workflow.ts` is runnable out of the box (connects to the running bootstrap).
The others are module-style — import and compose them in your orchestrator.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  bootstrap.ts (long-running)                        │
│  ┌──────────┐    ┌──────────────┐    ┌───────────┐  │
│  │  PGlite  │───▶│ Socket Server│◀───│   DBOS    │  │
│  │  (WASM)  │    │  :auto-port  │    │  Runtime  │  │
│  └──────────┘    └──────┬───────┘    └───────────┘  │
│                         │ tcp                        │
└─────────────────────────┼───────────────────────────┘
                          │
        ┌─────────────────┼─────────────────┐
        │                 │                 │
   ┌────┴─────┐    ┌──────┴──────┐    ┌────┴─────┐
   │ your     │    │ CLI tools   │    │ another  │
   │ workflow │    │ (dashboard, │    │ workflow │
   │ process  │    │  send, etc) │    │ process  │
   └──────────┘    └─────────────┘    └──────────┘
```

- **bootstrap** owns PGlite and the socket. Stays running.
- **workflow processes** connect via the socket, run their own DBOS instance.
- **CLI tools** use lightweight `DBOSClient` for read/management operations.
- All share the same Postgres database through the socket multiplexer.

### Key files

| Path | Purpose |
|------|---------|
| `src/db.ts` | PGlite lifecycle, socket server, connection.json |
| `src/dbos-config.ts` | DBOS config builder (PGlite-safe defaults) |
| `src/client.ts` | DBOSClient factory for CLI tools |
| `scripts/bootstrap.ts` | Start PGlite + DBOS, keep alive |
| `scripts/dashboard.ts` | Formatted workflow table |
| `scripts/inspect.ts` | Step-by-step execution trace |
| `scripts/evidence.ts` | Automated compatibility test suite |

## PGlite Constraints

These are hard requirements discovered through [automated testing](evidence-report.json):

| Constraint | Why |
|------------|-----|
| `systemDatabasePoolSize: 1` | PGlite serializes internally. Pool >= 2 deadlocks. |
| `useListenNotify: false` | pglite-socket doesn't relay NOTIFY messages. |
| `maxConnections: 20` on socket server | Default of 1 blocks concurrent access (ECONNRESET). |

All three are already set correctly in `src/db.ts` and `src/dbos-config.ts`. You
only need to know this if you're writing custom setup code or debugging connection
issues. See `references/pglite-notes.md` for the full evidence breakdown.

**None of these apply to external Postgres.** Set `DBOS_DATABASE_URL` and all
standard Postgres features (pool > 1, LISTEN/NOTIFY) work normally.

## External Postgres

Code works unchanged — set one env var:

```bash
export DBOS_DATABASE_URL=postgresql://user:pass@host:5432/dbname
npm run bootstrap   # verifies connection, creates system tables, exits
npx tsx my-workflow.ts
```

The config builder auto-detects external mode and enables pool > 1 and LISTEN/NOTIFY.

## References

- `references/dbos-typescript-api.md` — DBOS API surface
- `references/patterns-and-antipatterns.md` — what to do and what not to do
- `references/troubleshooting.md` — common errors and fixes
- `references/pglite-notes.md` — PGlite compatibility evidence and constraints
