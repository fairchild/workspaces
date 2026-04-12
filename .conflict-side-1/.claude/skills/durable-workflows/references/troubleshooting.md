# Troubleshooting

## ECONNRESET errors

**Cause**: Too many concurrent connections to PGlite's socket multiplexer.

**Fix**: Set `systemDatabasePoolSize: 1` in DBOS config. If using DBOSClient
alongside a running DBOS instance, shut down DBOS first and wait 1 second.

## "extension uuid-ossp is not available"

**Cause**: PGlite was created without the uuid_ossp extension.

**Fix**: Add the extension when creating PGlite:
```typescript
import { uuid_ossp } from "@electric-sql/pglite/contrib/uuid_ossp";
const db = await PGlite.create(dataDir, { extensions: { uuid_ossp } });
```

## Workflow not recovering on restart

**Cause**: Workflow function not registered before `DBOS.launch()`.

**Fix**: Register all workflow functions before calling `DBOS.launch()`:
```typescript
const wf = DBOS.registerWorkflow(myFn, { name: "myFn" });
await DBOS.launch(); // Recovery happens here
```

## "No database connection found"

**Cause**: CLI tool can't find `.dbos/connection.json`.

**Fix**: Run `npm run bootstrap` first, or set `DBOS_DATABASE_URL` env var.

## Step output too large / slow queries

**Cause**: Step returning very large objects (e.g., full LLM responses).

**Fix**: Return only what's needed for the workflow to continue. Store large
data externally (filesystem, S3) and return a reference/path as the step output.

## Workflow stuck in PENDING

**Possible causes**:
1. Waiting on `DBOS.recv()` — check the dashboard for waiting indicators
2. Crashed mid-step — will auto-recover on next `DBOS.launch()`
3. Step retrying with backoff — check step config

**Debug**: Use `npm run inspect <workflow-id>` to see which step it's on.

## Port already in use

**Cause**: Previous PGlite instance still running.

**Fix**: Run `npm run shutdown` or kill the process shown in `.dbos/connection.json`.
