---
status: pending
category: followup
pr: null
branch: null
---

# Workspace Creation Hang — Root Cause Investigation

## Context

PR #190 added diagnostics (os.Logger, 30s watchdog) and a debounced save rollback guard for the "Finishing workspace..." hang observed after Milestone 6. The hang was a local workspace creation that required force quit. No crash report was generated.

## What was done

- Added `os.Logger` tracing to `SidebarWorkspaceController`, `SidebarView`, and `ContentView` workspace creation paths
- Guarded `modelContext.rollback()` in the debounced `saveAccessTimestampChanges` to skip rollback when pending inserts exist
- Added 30-second watchdog that surfaces stalled creation in the UI and logs

## What remains

1. **Reproduce the hang** with the new diagnostics to confirm the exact stuck point via `log stream --predicate 'subsystem == "com.cloudcompute.workspaces" AND category == "WorkspaceCreation"'`
2. **Root cause the debounced save interaction** — the rollback guard is defensive but the underlying question is: can the debounced save's `modelContext.save()` conflict with `upsertWorkspace()`'s `modelContext.save()` on the same `ModelContext`?
3. **Consider separate ModelContext** for access timestamp persistence — isolates it completely from workspace creation saves
4. **Check if perf-baseline temp dir** (`/private/tmp/`) is a contributing factor — the original hang used a perf-baseline data dir that may have been cleaned by the system

## Key files

- `Sources/WorkspaceManager/Views/MainWindow/SidebarWorkspaceController.swift` — creation flow + save
- `Sources/WorkspaceManager/Views/MainWindow/ContentView.swift` — debounced save at line ~1398
- `Sources/WorkspaceManager/Views/MainWindow/SidebarView.swift` — watchdog + progress handler
