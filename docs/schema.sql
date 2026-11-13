-- WorkSpaces local state schema
-- =============================
--
-- This file is both documentation and a runnable SQLite schema for the native
-- app's local state sidecar database. It mirrors LocalStateStore schema version
-- 3 in Sources/WorkspaceManagerCore/Services/LocalStateStore.swift.
--
-- Keep this file manually in sync whenever LocalStateStore migrations change.
-- SwiftData remains the canonical store for Repository, Workspace, and Web
-- Source rows. This SQLite database records local state history for continuity,
-- diagnostics, and export.
--
-- Try it locally:
--
--   sqlite3 /tmp/workspaces-local-state.sqlite < docs/schema.sql
--   sqlite3 /tmp/workspaces-local-state.sqlite '.schema'
--
-- Runtime note: GRDB adds its own migration bookkeeping table when the app opens
-- the database. That internal table is intentionally not documented here.

PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA user_version = 3;

BEGIN;

-- Application-level key/value metadata for this sidecar store. The runtime
-- writes schema_version here so diagnostic exports can identify the app schema
-- without depending on GRDB's internal migration table.
CREATE TABLE IF NOT EXISTS local_state_metadata (
    key TEXT PRIMARY KEY NOT NULL,
    value TEXT NOT NULL,
    updated_at TEXT NOT NULL
) STRICT;

INSERT INTO local_state_metadata (key, value, updated_at)
VALUES ('schema_version', '3', strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
ON CONFLICT(key) DO UPDATE SET
    value = excluded.value,
    updated_at = excluded.updated_at;

-- Durable record of host terminal sessions known to the native app.
--
-- Domain mapping:
-- - Repository and Workspace identity is still owned by SwiftData.
-- - target_kind says how this terminal relates to the WorkSpaces domain.
-- - target_id is reserved for explicit Repository/Workspace UUIDs when a call
--   site has that identity.
-- - target_path captures current path-derived session keys.
-- - backend_identifier/backend_instance_id identify provider-backed sessions.
-- - tmux_session_name is nullable because tmux is mode-dependent. When set, it is
--   the session's *chosen* launch name (split panes carry a pane suffix beyond the
--   directory derivation); restore probes and reattaches by this exact value.
-- - ended_at is terminal for a host_session_id (#1239): the runtime upsert is
--   guarded on ended_at IS NULL and close keeps its first ended_at, so an
--   in-flight write racing a close can never resurrect a closed row into the
--   restore set. host_session_id is reused across runs on the default
--   (restoreSessionsOnLaunch off) path, where launch rehydrates the previous
--   run's tabs from the continuity manifest under their recorded ids; those rows
--   are live, so the guard passes and they move to the current run. A row that
--   is already ended stays ended under any later upsert.
-- - terminal_mode = 'unknown' marks a placeholder row: an agent event landed
--   before any surface recorded the session, and the event's foreign key needs a
--   row. The first surface upsert overwrites it with a real mode. Restore skips
--   placeholder rows; they are not tiles.
-- - last_seen_at advances when a state-changing write lands (the runtime drops
--   upserts whose row state is unchanged), not on every layout snapshot.
CREATE TABLE IF NOT EXISTS terminal_sessions (
    host_session_id TEXT PRIMARY KEY NOT NULL,
    session_key TEXT NOT NULL,
    target_kind TEXT NOT NULL
        CHECK (target_kind IN ('default_home', 'repo', 'workspace', 'host_path', 'backend_session')),
    target_id TEXT,
    target_path TEXT,
    backend_identifier TEXT,
    backend_instance_id TEXT,
    directory_path TEXT NOT NULL,
    terminal_mode TEXT NOT NULL,
    tmux_session_name TEXT,
    custom_command_present INTEGER NOT NULL DEFAULT 0
        CHECK (custom_command_present IN (0, 1)),
    hooks_socket_path TEXT,
    -- Selected tab for this terminal scope; more than one row can be selected
    -- globally when they belong to different Home/Repository/Workspace scopes.
    -- Selection only: a background tab or a split pane is open with is_active = 0,
    -- and whether a row is open is ended_at IS NULL. Restore reads it to pick
    -- which tab each scope comes back on.
    is_active INTEGER NOT NULL DEFAULT 0
        CHECK (is_active IN (0, 1)),
    created_at TEXT NOT NULL,
    last_seen_at TEXT NOT NULL,
    ended_at TEXT,
    -- App-run epoch (issue #783 #2): the process run that recorded this row, and
    -- when that run started. Cold-start restore offers only the single most
    -- recent prior run, so crash/reboot rows do not accumulate as "active"
    -- forever. NULL for rows written before schema v2 (added by ALTER TABLE).
    run_id TEXT,
    run_started_at TEXT,
    -- When the startup sweep staged this row as belonging to a run older than
    -- the restorable prior run (schema v3). A later launch that finds it still
    -- staged ends it; an upsert clears it. NULL for rows the sweep never staged.
    stale_since TEXT,
    -- When the tmux server holding this row's processes died while the app ran
    -- (schema v3). The row stays open (ended_at NULL), so the next run's restore
    -- set still carries it. A user close or a shell exit sets ended_at instead.
    -- An upsert clears it.
    holder_lost_at TEXT
) STRICT;

CREATE INDEX IF NOT EXISTS idx_terminal_sessions_target
    ON terminal_sessions(target_kind, target_id, target_path);
CREATE INDEX IF NOT EXISTS idx_terminal_sessions_last_seen
    ON terminal_sessions(last_seen_at DESC);
CREATE INDEX IF NOT EXISTS idx_terminal_sessions_run
    ON terminal_sessions(run_started_at DESC);

-- Point-in-time layout snapshots for the terminal surface. This table is ready
-- for UI restore and diagnostics even before every layout-producing call site
-- writes to it.
CREATE TABLE IF NOT EXISTS terminal_layout_snapshots (
    id TEXT PRIMARY KEY NOT NULL,
    captured_at TEXT NOT NULL,
    active_host_session_id TEXT,
    selected_surface_kind TEXT,
    selected_surface_id TEXT,
    FOREIGN KEY (active_host_session_id)
        REFERENCES terminal_sessions(host_session_id)
        ON DELETE SET NULL
) STRICT;

CREATE INDEX IF NOT EXISTS idx_terminal_layout_snapshots_captured
    ON terminal_layout_snapshots(captured_at DESC);

-- Split-pane details for a layout snapshot. The current product model is one
-- primary terminal plus an optional split for that primary terminal.
CREATE TABLE IF NOT EXISTS terminal_split_snapshots (
    snapshot_id TEXT NOT NULL,
    primary_host_session_id TEXT NOT NULL,
    split_host_session_id TEXT NOT NULL,
    axis TEXT NOT NULL CHECK (axis IN ('leading_trailing', 'top_bottom')),
    split_before_primary INTEGER NOT NULL CHECK (split_before_primary IN (0, 1)),
    split_fraction REAL NOT NULL CHECK (split_fraction >= 0.0 AND split_fraction <= 1.0),
    PRIMARY KEY (snapshot_id, primary_host_session_id),
    FOREIGN KEY (snapshot_id)
        REFERENCES terminal_layout_snapshots(id)
        ON DELETE CASCADE,
    FOREIGN KEY (primary_host_session_id)
        REFERENCES terminal_sessions(host_session_id)
        ON DELETE CASCADE,
    FOREIGN KEY (split_host_session_id)
        REFERENCES terminal_sessions(host_session_id)
        ON DELETE CASCADE
) STRICT;

-- Normalized agent state events from hooks, OSC, status line, transcript, and
-- bell inputs. Raw prompts and raw tool inputs are not persisted by default.
-- prompt_present records that a user prompt existed without storing the prompt.
-- tool_detail stores only a coarse safe marker such as command_present or
-- file_path_present; it must not contain raw commands, URLs, prompts, paths, or
-- tool payloads.
CREATE TABLE IF NOT EXISTS agent_status_events (
    id TEXT PRIMARY KEY NOT NULL,
    host_session_id TEXT NOT NULL,
    agent_session_id TEXT,
    agent_kind TEXT NOT NULL,
    origin TEXT NOT NULL CHECK (origin IN ('hook', 'osc', 'status_line', 'transcript', 'bell')),
    origin_detail TEXT,
    event_name TEXT NOT NULL,
    run_state TEXT NOT NULL,
    cwd TEXT NOT NULL,
    tool_name TEXT,
    tool_detail TEXT,
    awaiting_reason TEXT,
    error_category TEXT,
    error_message TEXT,
    prompt_present INTEGER NOT NULL DEFAULT 0 CHECK (prompt_present IN (0, 1)),
    model_display_name TEXT,
    context_used_percent REAL,
    five_hour_limit_used_percent REAL,
    five_hour_limit_resets_at TEXT,
    cost_usd REAL,
    event_at TEXT NOT NULL,
    FOREIGN KEY (host_session_id)
        REFERENCES terminal_sessions(host_session_id)
        ON DELETE CASCADE
) STRICT;

CREATE INDEX IF NOT EXISTS idx_agent_status_events_host_time
    ON agent_status_events(host_session_id, event_at DESC);
CREATE INDEX IF NOT EXISTS idx_agent_status_events_agent_session
    ON agent_status_events(agent_session_id, event_at DESC);
CREATE INDEX IF NOT EXISTS idx_agent_status_events_run_state
    ON agent_status_events(run_state, event_at DESC);

-- Local performance and startup diagnostics. labels_json is intentionally a
-- bounded JSON object of safe diagnostic labels, not arbitrary raw logs.
CREATE TABLE IF NOT EXISTS diagnostic_events (
    id TEXT PRIMARY KEY NOT NULL,
    metric TEXT NOT NULL,
    duration_ms REAL NOT NULL,
    labels_json TEXT NOT NULL DEFAULT '{}',
    event_at TEXT NOT NULL
) STRICT;

CREATE INDEX IF NOT EXISTS idx_diagnostic_events_metric_time
    ON diagnostic_events(metric, event_at DESC);

-- Diagnostic report export ledger. The export itself is a zip file; this table
-- keeps local metadata and row counts so support/debug flows can answer what
-- state existed when the report was produced.
CREATE TABLE IF NOT EXISTS diagnostic_exports (
    id TEXT PRIMARY KEY NOT NULL,
    created_at TEXT NOT NULL,
    app_version TEXT NOT NULL,
    build_number TEXT NOT NULL,
    filename TEXT NOT NULL,
    redaction_level TEXT NOT NULL,
    status TEXT NOT NULL,
    row_counts_json TEXT NOT NULL DEFAULT '{}'
) STRICT;

CREATE INDEX IF NOT EXISTS idx_diagnostic_exports_created
    ON diagnostic_exports(created_at DESC);

-- A lookup over the Conversation record files, one row per file in
-- $WORKSPACES_CONVERSATIONS_DIR (default <CLI config dir>/conversations). The
-- files are the truth: the app rebuilds this table from them at launch and
-- syncs it when the directory changes, and nothing else writes it, so it can be
-- dropped at any time. The current conversation of a tile is the row with the
-- newest observed_at for its host_session_id. Added by the GRDB migration named
-- "conversation_index"; liveness, run state, and prompt text are never stored.
CREATE TABLE IF NOT EXISTS conversation_index (
    conversation_id TEXT PRIMARY KEY NOT NULL,
    harness TEXT NOT NULL,
    host_session_id TEXT,
    tmux_server_pid INTEGER,
    tmux_session_id TEXT,
    cwd TEXT NOT NULL,
    observed_at TEXT NOT NULL
) STRICT;

CREATE INDEX IF NOT EXISTS idx_conversation_index_host_session
    ON conversation_index(host_session_id, observed_at DESC);

COMMIT;

-- Useful exploration queries:
--
-- Recent terminal sessions:
--   SELECT target_kind, target_path, directory_path, terminal_mode, is_active, last_seen_at
--   FROM terminal_sessions
--   ORDER BY last_seen_at DESC
--   LIMIT 20;
--
-- Agent state timeline for one host terminal session:
--   SELECT event_at, origin, event_name, run_state, tool_name, awaiting_reason
--   FROM agent_status_events
--   WHERE host_session_id = '<uuid>'
--   ORDER BY event_at ASC;
--
-- The conversation a tile holds now:
--   SELECT conversation_id, observed_at
--   FROM conversation_index
--   WHERE host_session_id = '<uuid>'
--   ORDER BY observed_at DESC
--   LIMIT 1;
--
-- Diagnostic event counts:
--   SELECT metric, count(*) AS events, max(event_at) AS latest
--   FROM diagnostic_events
--   GROUP BY metric
--   ORDER BY latest DESC;
