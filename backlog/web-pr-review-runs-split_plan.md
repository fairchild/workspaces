# Plan: split `web/src/lib/agent-runtime/pr-review-runs.ts` into domain / store / lifecycle

> Part 2 of a two-part architecture-deepening pass on `web/`. Part 1 (the schema
> seam) shipped in PR #624. This plan is self-contained — a fresh session can
> execute it without prior context.

## Context

`web/src/lib/agent-runtime/pr-review-runs.ts` is a ~2,100-line module with ~51
exports doing five jobs at once: row CRUD, the projection ledger, the run-status
state machine, coalescing, and failure classification. (Its table DDL already moved
out in Part 1 — it now calls `ensureSchema()` and owns no schema.) The interface is
nearly as large as the implementation; `pr-review.ts` imports 18 symbols and must
sequence them correctly, and the legal state transitions are encoded only in that
call order, stated nowhere.

The deepening: separate the **pure domain**, the **persistence** (reads + low-level
row writes), and the **lifecycle** (the verbs that encode legal transitions), behind
a **barrel** so every existing consumer and test keeps working unchanged.

**Decision already made (do not re-litigate):** a 3-module split with a stable barrel
and **no** test-injection / fakeable-`PrReviewRunStore`-interface refactor. The point
is locality + pure-domain testability now; collapsing `pr-review.ts`'s 18-symbol
import and introducing an injectable store interface are explicitly deferred.

## Target structure

Convert the file into a folder `web/src/lib/agent-runtime/pr-review-runs/` with a
barrel. The six consumers import the path `pr-review-runs` and must keep working
untouched: `pr-review.ts`, `app/api/webhooks/github/pr-reviewer-monitor/route.ts`,
`app/api/pr-review-runs/[fingerprint]/route.ts`, `app/api/managed-agents/transcript/route.ts`,
`app/dashboard/review-runs/[fingerprint]/page.tsx`, `…/review-run-recovery-action.tsx`.

- **`domain.ts`** — pure, no `getDb`/`getTurso` import:
  - Type unions: `PrReviewRunStatus`, `PrReviewProjectionStatus`, `PrReviewProjectionType`,
    `PrReviewProjectionLedgerState`, `PrReviewProjectionErrorKind`, `PrReviewFailureKind`,
    `PrReviewExecutionState`, `PrReviewRunOperatorState`, `PrReviewRunRecoveryAction`.
  - Interfaces (data shapes): `PrReviewRunReviewIntent`, `PrReviewRunFingerprintInput`,
    `PrReviewRunRecordInput`, `RecordRunStartResult`, `PrReviewProjectionRecord`,
    `BeginPrReviewProjectionAttemptInput`, `BeginPrReviewProjectionAttemptResult`,
    `RecordRunResultInput`, `PrReviewRunSummary`, `PrReviewRunDetails`, `StartedPrReviewRun`,
    `BrokerPrReviewRun`, `PrReviewRunRecoveryAvailability`, `ActivePrReviewRunSuccessor`,
    `PrReviewRunSuccessor`, `PrReviewRunStateThresholds`, `ClassifiedPrReviewRun`,
    `PrReviewRunStateBuckets`.
  - Pure functions: `computeRunFingerprint`, `classifyPrReviewProjectionError`,
    `classifyPrReviewRun`, `bucketPrReviewRuns`. Add `domain.test.ts` (these are
    trivially testable in isolation — the immediate win).
- **`store.ts`** — persistence reads + low-level row mutations; calls `ensureSchema()`;
  owns no DDL:
  - `getPrReviewRunByFingerprint`, `getPrReviewRunBySessionId`, `getActivePrReviewRunSuccessor`,
    `getNewerCurrentHeadPrReviewRun`, `getPrReviewRunByTrigger`, `listRecentPrReviewRuns`,
    `listPrReviewRunsForBroker`, `listStartedPrReviewRuns`, `listPrReviewProjectionsForRun`,
    plus the private row-mapper helpers and any low-level insert/update used by lifecycle.
- **`lifecycle.ts`** — the transition verbs (the state machine), orchestrating `store` + `domain`:
  - `recordRunStart` (the coalescing logic), `recordRunResult`, `markRunSessionStarted`,
    `markRunCompleted`, `markRunFailed`, `markRunSuperseded`, `beginPrReviewProjectionAttempt`,
    `recordPrReviewProjectionSuccess`, `recordPrReviewProjectionFailure`, `releaseRunActiveClaim`.
- **`index.ts`** (barrel) — `export * from "./domain"; export * from "./store"; export * from "./lifecycle";`
  and re-export `__resetPrReviewRunsForTests` (it currently delegates to `resetSchemaForTests()`).

Give each of `domain.ts`, `store.ts`, `lifecycle.ts` a short (2–4 line) top-of-file doc
block stating what it is and why, present-tense.

## Guidance / gotchas

- **Keep each function whole** — don't split one function across modules. The store/lifecycle
  boundary is fuzzy for `recordRunStart` (it reads, applies domain logic, and writes during
  coalescing); keep it in `lifecycle.ts` and let it call `store` reads + its own writes.
- **Behavior-preserving.** No logic changes — pure relocation. If a circular import appears
  (lifecycle→store→domain is fine; avoid store→lifecycle), move the shared helper down to
  `domain.ts` or `store.ts`.
- **`Database` is exported from `../db`** (Part 1) — use `Kysely<Database>` typing as needed.
- Do **not** introduce an injectable store interface or touch the big test files' mocking
  strategy.

## Verification

- `mise -C web run web:check` (typecheck + Biome + Vitest) must be green.
- The two large suites must stay green **unchanged**: `__tests__/pr-review-runs.test.ts`
  (910 lines, real `:memory:` DB, imports via the barrel) and `__tests__/pr-review.test.ts`
  (2,237 lines, mocks `pr-review-runs` via the barrel path). If either needs edits beyond
  import paths, the split changed behavior — back out and re-do.
- Confirm zero remaining imports of the old single-file path resolve incorrectly (the barrel
  at `pr-review-runs/index.ts` keeps `from ".../pr-review-runs"` working).
- New: `domain.ts` unit tests for the four pure functions.
- Evidence + PR per `web/docs/schema-management.md` siblings and the repo evidence gate
  (`./scripts/evidence.sh`); see also `docs/development/evidence.md`.

## How to start

1. Ensure PR #624 (Part 1) is merged to `main`, then branch off the updated `main`
   (Part 2 depends on `ensureSchema()` and the baseline owning the two `pr_review` tables).
   If #624 is not yet merged, base this branch on `c-web-architecture-review` instead and
   retarget to `main` after the merge.
2. Read `web/docs/schema-management.md` for how persistence/schema works post-Part-1.
3. Execute the split, run verification, open a separate PR.
