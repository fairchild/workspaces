# Local State Store Plan

This plan tracks the local SQLite sidecar that records WorkSpaces state history for continuity, diagnostics, and export. SwiftData remains the canonical store for Repository, Workspace, and Web Source rows. The SQLite store records append-friendly, queryable history around Terminal Sessions, Surfaces, agent state, and diagnostic events.

The foundation landed in PR #483 and shipped in WorkSpaces v0.15.0:

- GRDB-backed `LocalStateStore` with WAL mode, foreign keys, migrations, and summary reporting.
- Runtime tables for terminal sessions, terminal layout snapshots, split snapshots, agent status events, diagnostic events, and diagnostic export ledger rows.
- `docs/schema.sql` as the readable and runnable schema document. Keep it manually in sync with `LocalStateStore` migrations.
- App bootstrap, agent status event persistence, terminal session persistence, Diagnostics tab summary, and diagnostic report summary export.
- Agent event persistence writes only coarse tool-detail markers, never raw tool payloads.

## Goals

- Keep everything local. No cloud persistence, no remote sync, and no raw prompt storage by default.
- Give a new app process enough recent history to understand the previous Terminal Sessions and agent state.
- Give diagnostic exports a compact, safe summary of local state, with a path toward optional database snapshots later.
- Keep the schema understandable to coding agents and humans through `docs/schema.sql`, AGENTS guidance, and focused tests.

## Non-Goals

- Do not replace SwiftData as the owner of Repository, Workspace, or Web Source models.
- Do not persist raw terminal transcripts, raw prompts, raw tool payloads, secrets, or complete diagnostic logs in SQLite.
- Do not add cross-device sync or external storage.

## Implementation Slices

1. Persist startup diagnostics into `diagnostic_events`.
   - Attach `StartupDiagnosticsStore` to `LocalStateStore` during app bootstrap.
   - Flush existing in-memory events once and persist future events asynchronously.
   - Preserve the current hot-path behavior: diagnostics recording must not await disk I/O.
   - Tests: `StartupDiagnosticsStore` records events into a temporary `LocalStateStore`; existing export tests still pass.

2. Record richer Surface and terminal layout snapshots.
   - Write `terminal_layout_snapshots` when the selected Surface changes and when split state changes.
   - Include selected Surface kind/id using domain terms: repo overview, repository terminal, workspace terminal, or web source.
   - Include split pane rows from `HostTerminalStateStore`.
   - Tests: selecting Surfaces produces expected snapshot rows and split rows without requiring UI automation.

3. Add startup read models for continuity.
   - Add local-state queries for latest active Terminal Sessions, latest agent status per host session, and latest layout snapshot.
   - Keep restore conservative: resolve Repository/Workspace IDs through current SwiftData rows and fall back when a row is missing.
   - Tests: deleted or stale targets do not restore invalid Surfaces.
   - Status: store-level read models landed (`fetchContinuitySessions`, `fetchLatestLayoutSnapshot`); the conservative SwiftData resolution and restore orchestration happen in the caller and are tracked in the durable-sessions epic (issue #728).

4. Expose local state in diagnostics.
   - Initial Diagnostics tab section shows store mode, database path, schema version, table counts, and latest event times.
   - Follow-up: track and render last write failure if any.
   - Keep direct database actions explicit and local-only.
   - Tests: view model renders degraded/unavailable/persistent states.

5. Expand diagnostic exports safely.
   - Keep `local-state-summary.json` as the default safe export.
   - Consider an opt-in SQLite snapshot using SQLite backup or `VACUUM INTO` after redaction policy is settled.
   - Tests: default export never includes raw prompts or terminal transcript payloads.

6. Add retention and health checks.
   - Define retention for high-volume event tables.
   - Add a lightweight integrity probe with `PRAGMA quick_check`.
   - Add cleanup hooks for ended sessions and old diagnostic events.
   - Tests: retention deletes old rows while preserving recent continuity rows.

## Schema Stewardship

- `LocalStateStore.schemaVersion` and `docs/schema.sql` must change together.
- Any table/index/meaning change needs a runtime migration plus matching `docs/schema.sql` update.
- Keep comments in `docs/schema.sql` focused on concepts and relationships, not implementation trivia.
- Prefer additive migrations until a cleanup release explicitly removes obsolete fields.

## Verification

Every slice should run:

```bash
swift-format lint --strict --recursive Sources/ Tests/
swift test --filter 'LocalStateStoreTests|StartupDiagnosticsStoreTests|DiagnosticReportExporterTests'
```

Before PR creation, run full `swift test` and collect evidence according to `AGENTS.md`.
