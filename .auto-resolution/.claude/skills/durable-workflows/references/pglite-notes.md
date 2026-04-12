# PGlite Notes

## What It Is

PGlite is full Postgres compiled to WASM, running in Node.js with zero external
dependencies. ~3MB gzipped. Persists to filesystem. This is real Postgres — full
SQL, transactions, schemas, jsonb, extensions, etc.

## PGlite + DBOS Configuration

Required settings when using PGlite as the DBOS backend:

```typescript
DBOS.setConfig({
  systemDatabaseUrl: databaseUrl,
  systemDatabasePoolSize: 1,   // REQUIRED — pool>1 deadlocks (evidence Q1)
  useListenNotify: false,       // REQUIRED — socket doesn't relay notifications (evidence Q3)
  runAdminServer: false,
});
```

Socket server must set `maxConnections` > 1 for DBOSClient concurrent access:

```typescript
const server = new PGLiteSocketServer({
  db,
  port: 0,
  host: "127.0.0.1",
  maxConnections: 20,  // default is 1 — causes ECONNRESET
});
```

Required PGlite extension for DBOS:

```typescript
import { uuid_ossp } from "@electric-sql/pglite/contrib/uuid_ossp";

const db = await PGlite.create("./path/to/pgdata", {
  extensions: { uuid_ossp },
});
```

## Evidence-Based Findings

Results from `scripts/evidence.ts` (see `evidence-report.json` for full data):

| Question | Verdict | Key Finding |
|----------|---------|-------------|
| Q1: Pool sizes | PARTIAL | pool=1 works (15ms). pool>=2 deadlocks even with maxConnections=20 |
| Q2: Schema | PASS | DBOS creates `dbos` schema with 13 tables in PGlite |
| Q3: LISTEN/NOTIFY | PARTIAL | Raw PGlite delivers (201ms). Socket relay: no delivery. DBOS useListenNotify=true hangs — recv() waits for NOTIFY the socket never relays |
| Q4: Startup | PASS | Cold: ~1.6s, Warm: ~157ms, DBOS launch: ~84ms |
| Q5: DBOSClient | PASS | Concurrent clients work with maxConnections=20 |
| Q6: Payload size | PASS | 100KB at 0.5x baseline. 1MB: 43ms. Minimal pgdata growth |

## Key Limitations

1. **Pool size must be 1**: PGlite serializes all queries through a single
   internal connection. DBOS with pool>=2 deadlocks because concurrent pool
   connections contend on PGlite's serialization layer. This is fundamental,
   not fixable with `maxConnections`.

2. **LISTEN/NOTIFY disabled**: pglite-socket has zero notification relay code
   (Q3b: NOTIFY sent on PGlite never reaches a pg client through the socket).
   With `useListenNotify: true`, DBOS relies on NOTIFY for message delivery —
   since the socket never relays it, `recv()` hangs waiting for a notification
   that never arrives (Q3c: times out after 10s). With `useListenNotify: false`,
   DBOS falls back to polling automatically and everything works.

3. **maxConnections default is 1**: The socket server's `maxConnections: 1`
   default was the root cause of ECONNRESET errors in early testing. Set to
   20+ to allow DBOS + DBOSClient concurrent access.

4. **Connection cooldown**: After `DBOS.shutdown()`, wait ~500ms before
   creating new connections to avoid stale connection errors.

5. **Startup time**: Cold start ~1.6s (Postgres init + extension load).
   Warm start ~157ms. DBOS launch ~84ms. All well under 5s threshold.

## Performance Notes

- Step checkpoints are fast: 100B-1MB all complete in <50ms
- Large outputs (1MB): 43ms write, ~41KB pgdata growth
- 100KB outputs are actually faster than baseline (caching effects)
- Socket multiplexer adds minimal overhead for sequential operations
- DBOSClient concurrent access: 3 clients simultaneously works fine

## Promoting to External Postgres

Code developed against PGlite works unchanged with production Postgres.
Only change: set `DBOS_DATABASE_URL=postgresql://...` and remove PGlite
setup. With real Postgres, pool>1 and LISTEN/NOTIFY both work.
