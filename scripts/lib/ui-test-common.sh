#!/bin/bash
# Shared helpers for WorkspaceManager UI smoke/capture scripts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

APP_PID=""
ARTIFACT_DIR=""
APP_LOG=""
WIN_X=""
WIN_Y=""
WIN_W=""
WIN_H=""
TERMINAL_X=""
TERMINAL_Y=""
SIDEBAR_X=""
SIDEBAR_Y=""

ws_log() {
    echo "[$(date +%H:%M:%S)] $1"
}

ws_require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        ws_log "ERROR: missing required command: $cmd"
        exit 1
    fi
}

ws_permissions_hint() {
    cat <<'EOF'
Permission requirements:
  1) Accessibility (for cliclick)
  2) Automation access to System Events (for osascript)
  3) Screen Recording (for screenshots in capture mode)

Enable permissions in:
  System Settings -> Privacy & Security
EOF
}

ws_prepare_artifacts() {
    local prefix="$1"
    local timestamp
    timestamp="$(date +%Y%m%d-%H%M%S)"

    ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/${prefix}-${timestamp}}"
    APP_LOG="$ARTIFACT_DIR/app-output.log"
    mkdir -p "$ARTIFACT_DIR"
    rm -f "$APP_LOG"
}

ws_kill_existing() {
    pkill -f "WorkspaceManager" 2>/dev/null || true
    sleep 1
}

ws_stop_app() {
    if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
    fi
    APP_PID=""
}

ws_cleanup() {
    ws_stop_app
}

ws_register_cleanup_trap() {
    trap ws_cleanup EXIT
}

ws_build_app() {
    ws_log "Building app..."
    (
        cd "$REPO_ROOT"
        swift build
    )
    ws_log "Build successful."
}

ws_launch_app() {
    local wait_seconds="${1:-5}"
    ws_log "Launching app..."
    (
        cd "$REPO_ROOT"
        swift run WorkspaceManager > "$APP_LOG" 2>&1
    ) &
    APP_PID=$!
    sleep "$wait_seconds"

    if ! kill -0 "$APP_PID" 2>/dev/null; then
        ws_log "ERROR: WorkspaceManager exited early."
        ws_log "Last app log lines:"
        tail -n 40 "$APP_LOG" || true
        return 1
    fi
}

ws_activate_app() {
    if ! osascript -e 'tell application "System Events" to set frontmost of process "WorkspaceManager" to true' >/dev/null 2>&1; then
        ws_log "ERROR: could not activate WorkspaceManager window."
        ws_permissions_hint
        return 1
    fi
    sleep 0.5
}

ws_get_window_geometry() {
    local window_info
    window_info="$(osascript -e '
tell application "System Events"
    tell process "WorkspaceManager"
        set w to window 1
        set pos to position of w
        set sz to size of w
        return (item 1 of pos as text) & "," & (item 2 of pos as text) & "," & (item 1 of sz as text) & "," & (item 2 of sz as text)
    end tell
end tell
')" || {
        ws_log "ERROR: unable to read window geometry."
        ws_permissions_hint
        return 1
    }

    IFS=',' read -r WIN_X WIN_Y WIN_W WIN_H <<< "$window_info"
    if [[ -z "$WIN_X" || -z "$WIN_Y" || -z "$WIN_W" || -z "$WIN_H" ]]; then
        ws_log "ERROR: invalid window geometry output: '$window_info'"
        return 1
    fi
}

ws_compute_click_points() {
    local sidebar_width=250
    SIDEBAR_X=$((WIN_X + 120))
    SIDEBAR_Y=$((WIN_Y + 250))
    TERMINAL_X=$((WIN_X + sidebar_width + ((WIN_W - sidebar_width) / 3)))
    TERMINAL_Y=$((WIN_Y + WIN_H / 2))
}

ws_run_cliclick() {
    local output
    output="$(cliclick "$@" 2>&1)" || {
        ws_log "ERROR: cliclick failed for args: $*"
        ws_log "$output"
        ws_permissions_hint
        return 1
    }

    if [[ "$output" == *"Accessibility privileges not enabled"* ]]; then
        ws_log "ERROR: cliclick reports missing accessibility permissions."
        ws_log "$output"
        ws_permissions_hint
        return 1
    fi

    if [[ -n "$output" ]]; then
        ws_log "$output"
    fi
}

ws_click() {
    local x="$1"
    local y="$2"
    ws_run_cliclick "c:${x},${y}"
    sleep 0.3
}

ws_type() {
    local text="$1"
    ws_run_cliclick "t:${text}"
    sleep 0.3
}

ws_press_enter() {
    if ! osascript -e 'tell application "System Events" to key code 36' >/dev/null 2>&1; then
        ws_log "ERROR: could not send Enter key."
        ws_permissions_hint
        return 1
    fi
    sleep 0.6
}

ws_press_ctrl_c() {
    if ! osascript -e 'tell application "System Events" to keystroke "c" using control down' >/dev/null 2>&1; then
        ws_log "ERROR: could not send Ctrl+C."
        ws_permissions_hint
        return 1
    fi
    sleep 0.6
}

ws_take_screenshot() {
    local name="$1"
    local path="$ARTIFACT_DIR/${name}.png"
    if ! screencapture -x "$path"; then
        ws_log "ERROR: screenshot capture failed ($path)"
        ws_permissions_hint
        return 1
    fi
}

ws_print_artifacts() {
    ws_log "Artifacts saved to: $ARTIFACT_DIR"
    ls -la "$ARTIFACT_DIR"
}
