---
status: decided
date: 2026-06-07
decision: kysely-with-tracked-migrations
related:
  - web/docs/architecture.md
---

# Web Schema Toolchain: Kysely + Tracked Migrations (Drizzle Deferred)

## Decision

**The `web/` app stays on Kysely for queries and gains a centralized, tracked
versioned-migration runner (`ensureSchema()` + a `schema_migrations` table).
Drizzle is deliberately not adopted now.** A future move to Drizzle (typed schema +
generated migrations) remains open as its own ADR'd change, but is out of scope for
the schema-deepening work.

## Context

Schema bootstrap was copy-pasted across nine persistence modules — each with a
module-local `migrated` flag, an `ensure*Table()` doing `createTable().ifNotExists()`
plus best-effort `alterTable().addColumn()` in a swallowed `try/catch`, inline
indexes, and a bespoke `__reset*ForTests()`. The deepening consolidates this behind
one `ensureSchema()` seam with an ordered, tracked migration list. While planning it,
we asked whether to adopt Drizzle for schema management instead.

## Why not Drizzle (now)

A spike (`.context/drizzle-spike.md`, throwaway) settled the two questions that drove
the choice:

- **The custom `libsql-dialect.ts` is not a burden.** It is 81 trivial lines bridging
  the official `@libsql/client` into Kysely, reusing Kysely's stock `SqliteAdapter`,
  `SqliteIntrospector`, and `SqliteQueryCompiler`. No embedded-replica logic, nothing
  bespoke. The "large custom dialect to maintain" argument — the strongest reason to
  switch — was based on a wrong line count and does not hold. (Introspection works, so
  the baseline migration's add-missing-columns step can use
  `db.introspection.getTables()`.)
- **Drizzle's migrate model is an operational change we don't want bundled here.**
  Today the app has no build-time DB step: schema bootstraps at request time,
  once per warm serverless instance, idempotently. Drizzle's clean path
  (`drizzle-kit migrate` at deploy) adds a deploy step with prod Turso credentials in
  CI and a new failure mode; its runtime `migrate()` needs migration files bundled
  into the Next.js function (known friction) and reads `__drizzle_migrations` on each
  cold start. The Kysely plan keeps the existing operational model untouched while
  still delivering tracked versioned migrations (~60 lines).
- **Adoption cost is real and orthogonal to the deepening.** Drizzle means a
  query-layer rewrite across ~7 Kysely modules, reconciling the two raw-SQL modules
  (`repos.ts`, `terminal-tickets.ts`) that bypass Kysely via `getTurso()`, and
  baseline-against-prod reconciliation. None of it helps the parallel `pr-review-runs`
  split, which is ORM-agnostic.

## Consequences

- The deepening centralizes schema behind a single `ensureSchema()` seam, which also
  **de-risks** any future Drizzle adoption: one seam to replace instead of nine
  scattered `ensure*Table()` functions, with the dialect question already answered.
- If typed schema and generated migrations become desirable as a platform choice, the
  remaining decision is mostly query-layer rewrite cost plus the build-time-migrate
  operational shift — to be recorded in its own ADR at that time.
