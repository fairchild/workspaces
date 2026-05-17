-- WorkSpaces local state schema
-- =============================
--
-- This file is both documentation and a runnable SQLite schema for the native
-- app's local state sidecar database. It mirrors LocalStateStore schema version
-- 1 in Sources/WorkspaceManagerCore/Services/LocalStateStore.swift.
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
PRAGMA user_version = 1;

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
VALUES ('schema_version', '1', strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
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
-- - tmux_session_name is nullable because tmux is mode-dependent.
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
    is_active INTEGER NOT NULL DEFAULT 0
        CHECK (is_active IN (0, 1)),
    created_at TEXT NOT NULL,
    last_seen_at TEXT NOT NULL,
    ended_at TEXT
) STRICT;

CREATE INDEX IF NOT EXISTS idx_terminal_sessions_target
    ON terminal_sessions(target_kind, target_id, target_path);
CREATE INDEX IF NOT EXISTS idx_terminal_sessions_last_seen
    ON terminal_sessions(last_seen_at DESC);

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
-- Diagnostic event counts:
--   SELECT metric, count(*) AS events, max(event_at) AS latest
--   FROM diagnostic_events
--   GROUP BY metric
--   ORDER BY latest DESC;
