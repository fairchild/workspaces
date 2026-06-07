# Web Schema Management

The web app's database (LibSQL/Turso, queried through Kysely) follows one rule:
**one place defines the schema, one function applies it, and every query goes
through that function.** This doc says where each of those lives, the model that
runs them, and the tradeoffs behind the design.

> Not the desktop schema. `docs/schema.sql` is the **macOS app's** local SQLite
> sidecar (`LocalStateStore`) — a different database. The web schema described
> here lives in code (`src/lib/schema/migrations.ts`), not in `docs/schema.sql`.

## Where things live

| You want… | Read | What it is |
|-----------|------|------------|
| What tables exist + their columns/indexes | `src/lib/schema/migrations.ts` | The ordered `MIGRATIONS` list. `0001_baseline` defines every table, index, and data migration — the **source of truth for the schema**. |
| The typed row shapes | `src/lib/db.ts` (`Database` interface) | The TypeScript contract Kysely queries are checked against. |
| What runs the schema | `src/lib/schema/index.ts` | `ensureSchema()` applies pending migrations once; `resetSchemaForTests()` for tests. |
| The connection | `src/lib/db.ts` | `getTurso()` (raw libsql client) and `getDb()` (Kysely over the same client). |

Short version: **schema is defined in `migrations.ts`; it is run by `ensureSchema()` in `schema/index.ts`.**

## How it runs

Every persistence query awaits `ensureSchema()` before touching the database:

```ts
export async function getEvents(/* … */) {
  await ensureSchema();
  const db = getDb();
  // … query
}
```

```
query() ─ await ensureSchema() ─┬─ first call ──▶ runMigrations()
                                │                    ├─ CREATE TABLE schema_migrations (if absent)
                                │                    ├─ read already-applied ids
                                │                    └─ for each pending migration: up(getDb()); record id
                                └─ later calls ──▶ the cached promise (a no-op)

getDb()/getTurso() ─▶ one libsql client (Turso remote in prod; file: in dev; :memory: in tests)
```

`ensureSchema()`:

1. memoizes a single in-flight promise inside one warm serverless instance, so same-process callers share one bootstrap (and a failure clears the memo so a later request retries);
2. ensures the `schema_migrations` bookkeeping table exists;
3. reads which migration ids have already run;
4. runs each pending migration's `up()` in order, recording its id only after it succeeds.

It runs **at request time, once per warm serverless instance** — there is no separate build- or deploy-time DB step. The first query after a cold start triggers the bootstrap; every call after that is a cached no-op. Separate cold starts can overlap, so migrations are written to tolerate another instance making the same DDL change first and the migration record insert is idempotent.

## Changing the schema

- **Append** a new migration to `MIGRATIONS`: `{ id: "0002_add_thing", up: async (db) => { … } }`. Use a zero-padded, ordered id.
- **Never edit a migration that has shipped.** It's already recorded in `schema_migrations` on production and will not re-run. Add a new migration instead.
- **Keep `up()` idempotent**: `createTable().ifNotExists()`, `createIndex().ifNotExists()`, introspection-guarded column adds (see `addMissingColumns`), idempotent data `UPDATE`s. The runner records a migration only after `up()` succeeds; a partial failure is re-run from the top on the next request, and overlapping cold starts can run the same pending `up()` at the same time.
- **Put data migrations** (backfills, renames) in a migration, not in a query module. The `terminal`→`shell` rename and `owner_id` backfill live in `0001_baseline` for exactly this reason.
- **Add the row type** to the `Database` interface in `db.ts` for typed Kysely access. Two tables — `user_repos` and `terminal_access_tickets` — are instead queried via raw `getTurso()` SQL; their DDL still lives in the baseline so *all* schema stays in one place.

## Principles

- **One ordered source.** The schema is the migration list, read top to bottom — not assembled from scattered per-module bootstraps.
- **Append-only and tracked.** `schema_migrations` records what has run; migrations are never edited after shipping.
- **Idempotent, so re-runs are safe.** Cold starts and partial failures re-enter `up()` without harm.
- **Reconcile, don't assume.** `0001_baseline` introspects (`PRAGMA table_info`) and adds only missing columns — no swallowed `try/catch` — so it is safe against the existing production database, which predates `schema_migrations`.

## Tradeoffs (and what we did not do)

The decision record is `docs/decisions/web-schema-toolchain.md`. In short:

- **Kysely + an in-code tracked-migration runner, not Drizzle.** The custom libsql dialect is a trivial 81-line bridge, so it isn't a maintenance burden worth escaping; Drizzle would add a deploy-time migrate model this app doesn't have, plus a query-layer rewrite, for no gain on this work. Revisiting Drizzle is its own future ADR.
- **Request-time bootstrap, not build/deploy-time migration.** Keeps deploys free of a DB step and prod credentials out of CI; the cost is a small idempotent check on the first request per warm instance.
- **One baseline, not re-derived history.** We don't need the old per-deploy column-add history. The baseline reconciles any existing database; future changes are clean append-only migrations.

## Testing

- Tests run against an in-memory libsql DB (`TURSO_DATABASE_URL=:memory:`) with `vi.resetModules()` so each gets a fresh schema; `resetSchemaForTests()` forgets the memo between runs.
- `src/lib/schema/__tests__/schema.test.ts` is the cutover-safety suite: fresh build, idempotent re-run, and reconciliation of a pre-migration database that has real rows and no `schema_migrations` entry.
