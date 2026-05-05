#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

LAUNCH_SCRIPT="$REPO_ROOT/scripts/launch-dev.sh"
CAPTURE_SCRIPT="$REPO_ROOT/scripts/capture-window.sh"
PROBE_SCRIPT="$REPO_ROOT/scripts/tmux-continuity-probe.sh"
PREF_DOMAIN="com.cloudcompute.workspaces"

TARGET_PATH="$HOME/code/workspaces"
LABEL="app-restart"
RUN_ROOT="$REPO_ROOT/output/continuity-evidence"
RUN_DIR=""
WINDOW_TIMEOUT_SECONDS=15
NO_BUILD=false
TRUST_MISE=false

TARGET_REAL_PATH=""
DATA_DIR=""
SUMMARY_PATH=""
SUMMARY_WRITTEN=false
STATUS="failed"
FAILURE_REASON=""

BEFORE_PID=""
BEFORE_WINDOW_ID=""
BEFORE_LOG=""
BEFORE_CAPTURED_AT=""
BEFORE_TMUX_SESSION=""
AFTER_PID=""
AFTER_WINDOW_ID=""
AFTER_LOG=""
AFTER_CAPTURED_AT=""
RESTORE_ELAPSED_SECONDS=""
CLOSE_PROOF_TXT=""
CLOSE_PROOF_PNG=""
PROBE_START_LOG=""
PROBE_CHECK_LOG=""
PROBE_CLEANUP_LOG=""

PREF_LAST_SURFACE_HAD=false
PREF_LAST_SURFACE_VALUE=""
PREF_CONTINUITY_MANIFEST_HAD=false
PREF_CONTINUITY_MANIFEST_VALUE=""

usage() {
    cat <<'USAGE'
Usage: ./scripts/continuity-evidence.sh [options]

Options:
  --target <path>       Local repo/workspace path to validate (default: ~/code/workspaces)
  --label <label>       Label for tmux continuity probe artifacts (default: app-restart)
  --output-dir <path>   Artifact directory (default: output/continuity-evidence/<timestamp>)
  --no-build            Reuse the current debug binary
  --trust-mise          Trust this repo's .mise.toml before launch
  --window-timeout <s>  Visible-window timeout passed to launch-dev.sh (default: 15)
  --help, -h            Show this help

What it proves:
  - debug app opens a local repo terminal in tmux_per_session mode
  - the exact app pid exits after normal termination
  - relaunch restores the same terminal surface from persisted continuity state
  - the Workspaces tmux socket survives the app terminate/relaunch boundary

The script writes an evidence bundle under output/continuity-evidence/ and does
not upload artifacts. Upload before/closed/after PNGs with scripts/evidence.sh.
USAGE
}

log() {
    echo "[$(date +%H:%M:%S)] $*"
}

fail() {
    FAILURE_REASON="$*"
    echo "ERROR: $*" >&2
    exit 1
}

expand_path() {
    local path="$1"
    if [[ "$path" == "~" ]]; then
        printf "%s\n" "$HOME"
    elif [[ "$path" == "~/"* ]]; then
        printf "%s\n" "$HOME/${path#~/}"
    else
        printf "%s\n" "$path"
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target)
                [[ $# -ge 2 ]] || fail "--target requires a value"
                TARGET_PATH="$2"
                shift 2
                ;;
            --label)
                [[ $# -ge 2 ]] || fail "--label requires a value"
                LABEL="$2"
                shift 2
                ;;
            --output-dir)
                [[ $# -ge 2 ]] || fail "--output-dir requires a value"
                RUN_DIR="$2"
                shift 2
                ;;
            --no-build)
                NO_BUILD=true
                shift
                ;;
            --trust-mise)
                TRUST_MISE=true
                shift
                ;;
            --window-timeout)
                [[ $# -ge 2 ]] || fail "--window-timeout requires a value"
                [[ "$2" =~ ^[0-9]+$ ]] || fail "--window-timeout must be an integer"
                WINDOW_TIMEOUT_SECONDS="$2"
                shift 2
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                fail "Unknown argument: $1"
                ;;
        esac
    done
}

ensure_dependencies() {
    command -v swift >/dev/null 2>&1 || fail "swift is required"
    command -v screencapture >/dev/null 2>&1 || fail "screencapture is required"
    command -v tmux >/dev/null 2>&1 || fail "tmux is required"
    command -v qlmanage >/dev/null 2>&1 || fail "qlmanage is required to render close proof"
    [[ -x "$LAUNCH_SCRIPT" ]] || fail "missing launch script: $LAUNCH_SCRIPT"
    [[ -x "$CAPTURE_SCRIPT" ]] || fail "missing capture script: $CAPTURE_SCRIPT"
    [[ -x "$PROBE_SCRIPT" ]] || fail "missing tmux probe script: $PROBE_SCRIPT"
}

prepare_paths() {
    TARGET_PATH="$(expand_path "$TARGET_PATH")"
    [[ -d "$TARGET_PATH" ]] || fail "target path is not a directory: $TARGET_PATH"
    TARGET_REAL_PATH="$(cd "$TARGET_PATH" && pwd -P)"

    if [[ -z "$RUN_DIR" ]]; then
        RUN_DIR="$RUN_ROOT/$(date +%Y%m%d-%H%M%S)"
    else
        RUN_DIR="$(expand_path "$RUN_DIR")"
    fi
    mkdir -p "$RUN_DIR"
    RUN_DIR="$(cd "$RUN_DIR" && pwd)"
    DATA_DIR="$RUN_DIR/data"
    SUMMARY_PATH="$RUN_DIR/summary.json"
    CLOSE_PROOF_TXT="$RUN_DIR/closed-process-proof.txt"
    CLOSE_PROOF_PNG="$RUN_DIR/closed-process-proof.txt.png"
    PROBE_START_LOG="$RUN_DIR/tmux-probe-start.log"
    PROBE_CHECK_LOG="$RUN_DIR/tmux-probe-check.log"
    PROBE_CLEANUP_LOG="$RUN_DIR/tmux-probe-cleanup.log"
}

read_pref() {
    local key="$1"
    defaults read "$PREF_DOMAIN" "$key" 2>/dev/null
}

preserve_preferences() {
    local value
    if value="$(read_pref mainWindow.lastSurface)"; then
        PREF_LAST_SURFACE_HAD=true
        PREF_LAST_SURFACE_VALUE="$value"
    fi
    if value="$(read_pref terminalContinuity.manifest.v1)"; then
        PREF_CONTINUITY_MANIFEST_HAD=true
        PREF_CONTINUITY_MANIFEST_VALUE="$value"
    fi
}

set_continuity_preferences() {
    log "Using terminal mode override: tmux_per_session"
    defaults delete "$PREF_DOMAIN" mainWindow.lastSurface >/dev/null 2>&1 || true
    defaults delete "$PREF_DOMAIN" terminalContinuity.manifest.v1 >/dev/null 2>&1 || true
}

restore_preferences() {
    if [[ "$PREF_LAST_SURFACE_HAD" == true ]]; then
        defaults write "$PREF_DOMAIN" mainWindow.lastSurface "$PREF_LAST_SURFACE_VALUE"
    else
        defaults delete "$PREF_DOMAIN" mainWindow.lastSurface >/dev/null 2>&1 || true
    fi

    if [[ "$PREF_CONTINUITY_MANIFEST_HAD" == true ]]; then
        defaults write "$PREF_DOMAIN" terminalContinuity.manifest.v1 "$PREF_CONTINUITY_MANIFEST_VALUE"
    else
        defaults delete "$PREF_DOMAIN" terminalContinuity.manifest.v1 >/dev/null 2>&1 || true
    fi
}

json_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    printf "%s" "$value"
}

write_summary() {
    local status="$1"
    local failure="$2"
    cat >"$SUMMARY_PATH" <<JSON
{
  "status": "$(json_escape "$status")",
  "failure": "$(json_escape "$failure")",
  "target_path": "$(json_escape "$TARGET_REAL_PATH")",
  "label": "$(json_escape "$LABEL")",
  "run_dir": "$(json_escape "$RUN_DIR")",
  "data_dir": "$(json_escape "$DATA_DIR")",
  "before": {
    "pid": "$(json_escape "$BEFORE_PID")",
    "window_id": "$(json_escape "$BEFORE_WINDOW_ID")",
    "captured_at": "$(json_escape "$BEFORE_CAPTURED_AT")",
    "screenshot": "$(json_escape "$RUN_DIR/before-close.png")",
    "launch_log": "$(json_escape "$BEFORE_LOG")",
    "tmux_session": "$(json_escape "$BEFORE_TMUX_SESSION")"
  },
  "closed": {
    "proof_text": "$(json_escape "$CLOSE_PROOF_TXT")",
    "proof_png": "$(json_escape "$CLOSE_PROOF_PNG")"
  },
  "after": {
    "pid": "$(json_escape "$AFTER_PID")",
    "window_id": "$(json_escape "$AFTER_WINDOW_ID")",
    "captured_at": "$(json_escape "$AFTER_CAPTURED_AT")",
    "screenshot": "$(json_escape "$RUN_DIR/after-reopen.png")",
    "launch_log": "$(json_escape "$AFTER_LOG")",
    "restore_elapsed_seconds": "$(json_escape "$RESTORE_ELAPSED_SECONDS")"
  },
  "tmux_probe": {
    "start_log": "$(json_escape "$PROBE_START_LOG")",
    "check_log": "$(json_escape "$PROBE_CHECK_LOG")",
    "cleanup_log": "$(json_escape "$PROBE_CLEANUP_LOG")"
  }
}
JSON
}

parse_launch_pid() {
    sed -nE 's/.*WorkspaceManager running \(pid=([0-9]+)\).*/\1/p' "$1" | tail -n 1
}

parse_launch_window_id() {
    awk '/Verified visible window id:/ {print $NF}' "$1" | tail -n 1
}

parse_launch_log_path() {
    sed -nE 's/.*Log file: (.*)$/\1/p' "$1" | tail -n 1
}

wait_for_log_pattern() {
    local file="$1"
    local pattern="$2"
    local timeout_seconds="$3"
    local waited=0

    while (( waited < timeout_seconds )); do
        if [[ -f "$file" ]] && grep -E "$pattern" "$file" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done

    return 1
}

parse_tmux_session_from_log() {
    sed -nE 's/.*tmux_session=([^ ]+) mode=tmux_per_session.*/\1/p' "$1" | tail -n 1
}

capture_window() {
    local pid="$1"
    local window_id="$2"
    local output="$3"

    if [[ -n "$window_id" ]] && screencapture -x -l "$window_id" "$output"; then
        return 0
    fi

    "$CAPTURE_SCRIPT" --pid "$pid" --output "$output" >/dev/null
}

window_count_for_pid() {
    local pid="$1"
    WORKSPACES_CAPTURE_OWNER_PID="$pid" swift - <<'SWIFT'
import CoreGraphics
import Foundation

let targetPID = Int(ProcessInfo.processInfo.environment["WORKSPACES_CAPTURE_OWNER_PID"] ?? "") ?? -1
let ownerCandidates: Set<String> = ["WorkSpaces", "WorkspaceManager"]
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
var count = 0

for window in windows {
    let owner = window[kCGWindowOwnerName as String] as? String ?? ""
    let layer = window[kCGWindowLayer as String] as? Int ?? 1
    let ownerPID = window[kCGWindowOwnerPID as String] as? Int ?? -1
    if ownerCandidates.contains(owner), layer == 0, ownerPID == targetPID {
        count += 1
    }
}

print(count)
SWIFT
}

terminate_app_pid() {
    local pid="$1"
    TARGET_PID="$pid" swift - <<'SWIFT'
import AppKit
import Foundation

guard
    let rawPID = ProcessInfo.processInfo.environment["TARGET_PID"],
    let pid = Int32(rawPID)
else {
    exit(64)
}

guard let app = NSRunningApplication(processIdentifier: pid_t(pid)) else {
    exit(0)
}

exit(app.terminate() ? 0 : 1)
SWIFT
}

wait_for_pid_exit() {
    local pid="$1"
    local timeout_half_seconds=40
    local attempt

    for ((attempt = 0; attempt < timeout_half_seconds; attempt++)); do
        if ! kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        sleep 0.5
    done

    return 1
}

write_close_proof() {
    local window_count
    window_count="$(window_count_for_pid "$BEFORE_PID")"

    {
        echo "closed-check-date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "before-pid=$BEFORE_PID"
        echo "before-window-id=$BEFORE_WINDOW_ID"
        echo "remaining-window-count-for-pid=$window_count"
        if ps -p "$BEFORE_PID" -o pid=,command=; then
            echo "result=FAILED still running"
            return 1
        fi
        if [[ "$window_count" != "0" ]]; then
            echo "result=FAILED windows still visible for pid"
            return 1
        fi
        echo "result=PASS pid is no longer running after NSRunningApplication.terminate()"
    } >"$CLOSE_PROOF_TXT"
}

render_close_proof() {
    qlmanage -t -s 1000 -o "$RUN_DIR" "$CLOSE_PROOF_TXT" >/dev/null
    [[ -f "$CLOSE_PROOF_PNG" ]] || fail "close proof PNG was not created: $CLOSE_PROOF_PNG"
}

launch_debug_app() {
    local output_file="$1"
    local clean_flag="$2"
    local auto_select_flag="$3"
    local -a args=("--data-dir" "$DATA_DIR" "--window-timeout" "$WINDOW_TIMEOUT_SECONDS")

    [[ "$NO_BUILD" == true ]] && args+=("--no-build")
    [[ "$TRUST_MISE" == true ]] && args+=("--trust-mise")
    [[ "$clean_flag" == true ]] && args+=("--clean-data")
    args+=("--env" "WORKSPACES_TERMINAL_MULTIPLEXING_MODE=tmux_per_session")
    [[ "$auto_select_flag" == true ]] && args+=("--env" "WORKSPACES_PERF_AUTO_SELECT_FIRST_REPO=1")
    [[ "$auto_select_flag" == true ]] && args+=("--env" "WORKSPACES_PERF_AUTO_SELECT_REPO_PATH=$TARGET_REAL_PATH")

    (
        cd "$REPO_ROOT"
        "$LAUNCH_SCRIPT" "${args[@]}"
    ) | tee "$output_file"
}

run_probe_start() {
    "$PROBE_SCRIPT" cleanup "$TARGET_REAL_PATH" "$LABEL" >"$PROBE_CLEANUP_LOG" 2>&1 || true
    "$PROBE_SCRIPT" start "$TARGET_REAL_PATH" "$LABEL" >"$PROBE_START_LOG" 2>&1
}

run_probe_check() {
    "$PROBE_SCRIPT" check "$TARGET_REAL_PATH" "$LABEL" >"$PROBE_CHECK_LOG" 2>&1
}

run_probe_cleanup() {
    "$PROBE_SCRIPT" cleanup "$TARGET_REAL_PATH" "$LABEL" >>"$PROBE_CLEANUP_LOG" 2>&1 || true
}

terminate_pid_if_running() {
    local pid="$1"
    [[ -n "$pid" ]] || return 0
    terminate_app_pid "$pid" >/dev/null 2>&1 || true
    wait_for_pid_exit "$pid" >/dev/null 2>&1 || true
}

cleanup() {
    local exit_code=$?
    set +e

    terminate_pid_if_running "$AFTER_PID"
    terminate_pid_if_running "$BEFORE_PID"
    run_probe_cleanup
    restore_preferences

    if [[ "$SUMMARY_WRITTEN" != true && -n "$SUMMARY_PATH" ]]; then
        write_summary "failed" "$FAILURE_REASON"
    fi

    exit "$exit_code"
}

run() {
    parse_args "$@"
    ensure_dependencies
    prepare_paths
    preserve_preferences
    trap cleanup EXIT

    set_continuity_preferences
    run_probe_start

    local before_launch_out="$RUN_DIR/launch-before.log"
    log "Launching before-close app state..."
    launch_debug_app "$before_launch_out" true true
    BEFORE_PID="$(parse_launch_pid "$before_launch_out")"
    BEFORE_WINDOW_ID="$(parse_launch_window_id "$before_launch_out")"
    BEFORE_LOG="$(parse_launch_log_path "$before_launch_out")"
    [[ -n "$BEFORE_PID" && -n "$BEFORE_WINDOW_ID" && -n "$BEFORE_LOG" ]] \
        || fail "could not parse before launch pid/window/log"

    wait_for_log_pattern "$BEFORE_LOG" 'TerminalContinuity.*mode=tmux_per_session' 20 \
        || fail "before launch did not persist terminal continuity in tmux mode"
    BEFORE_TMUX_SESSION="$(parse_tmux_session_from_log "$BEFORE_LOG")"
    [[ -n "$BEFORE_TMUX_SESSION" ]] || fail "could not parse tmux session from before launch log"
    tmux -L workspaces has-session -t "$BEFORE_TMUX_SESSION" \
        >"$RUN_DIR/app-tmux-session-before.log" 2>&1 \
        || fail "app tmux session was not present: $BEFORE_TMUX_SESSION"

    capture_window "$BEFORE_PID" "$BEFORE_WINDOW_ID" "$RUN_DIR/before-close.png"
    BEFORE_CAPTURED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    log "Terminating before-close app pid=$BEFORE_PID..."
    terminate_app_pid "$BEFORE_PID"
    wait_for_pid_exit "$BEFORE_PID" || fail "before app pid did not exit: $BEFORE_PID"
    write_close_proof
    render_close_proof
    run_probe_check

    local after_launch_out="$RUN_DIR/launch-after.log"
    local restore_started_at restore_finished_at
    restore_started_at="$(date +%s)"
    log "Relaunching without auto-selection..."
    launch_debug_app "$after_launch_out" false false
    restore_finished_at="$(date +%s)"
    RESTORE_ELAPSED_SECONDS="$((restore_finished_at - restore_started_at))"

    AFTER_PID="$(parse_launch_pid "$after_launch_out")"
    AFTER_WINDOW_ID="$(parse_launch_window_id "$after_launch_out")"
    AFTER_LOG="$(parse_launch_log_path "$after_launch_out")"
    [[ -n "$AFTER_PID" && -n "$AFTER_WINDOW_ID" && -n "$AFTER_LOG" ]] \
        || fail "could not parse after launch pid/window/log"

    wait_for_log_pattern "$AFTER_LOG" 'TerminalContinuity.*mode=tmux_per_session' 20 \
        || fail "after launch did not restore and persist terminal continuity in tmux mode"
    tmux -L workspaces has-session -t "$BEFORE_TMUX_SESSION" \
        >"$RUN_DIR/app-tmux-session-after.log" 2>&1 \
        || fail "app tmux session was not present after relaunch: $BEFORE_TMUX_SESSION"

    capture_window "$AFTER_PID" "$AFTER_WINDOW_ID" "$RUN_DIR/after-reopen.png"
    AFTER_CAPTURED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    STATUS="passed"
    SUMMARY_WRITTEN=true
    write_summary "$STATUS" ""

    log "Continuity evidence passed."
    log "Run directory: $RUN_DIR"
    log "Before screenshot: $RUN_DIR/before-close.png"
    log "Closed proof: $CLOSE_PROOF_PNG"
    log "After screenshot: $RUN_DIR/after-reopen.png"
    log "Summary: $SUMMARY_PATH"
}

run "$@"
