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
WIN_ID=""
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
    local data_dir="${WORKSPACES_DATA_DIR:-$REPO_ROOT/.sandbox-data}"

    mkdir -p "$data_dir"
    ws_log "Launching app..."
    (
        cd "$REPO_ROOT"
        WORKSPACES_DATA_DIR="$data_dir" swift run WorkspaceManager > "$APP_LOG" 2>&1
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
    local attempts=10
    local delay_seconds=1
    local attempt
    local window_info

    for ((attempt = 1; attempt <= attempts; attempt++)); do
        if window_info="$(
            swift - <<'SWIFT'
import CoreGraphics
import Foundation

let ownerCandidates: Set<String> = ["Workspaces", "WorkspaceManager"]
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

for window in windows {
    let owner = window[kCGWindowOwnerName as String] as? String ?? ""
    let layer = window[kCGWindowLayer as String] as? Int ?? 1
    guard ownerCandidates.contains(owner), layer == 0 else { continue }

    if let bounds = window[kCGWindowBounds as String] as? [String: Any],
       let x = bounds["X"] as? Double,
       let y = bounds["Y"] as? Double,
       let width = bounds["Width"] as? Double,
       let height = bounds["Height"] as? Double {
        print("\(Int(x.rounded())),\(Int(y.rounded())),\(Int(width.rounded())),\(Int(height.rounded()))")
        exit(0)
    }
}

exit(1)
SWIFT
        )"; then
            IFS=',' read -r WIN_X WIN_Y WIN_W WIN_H <<< "$window_info"
            if [[ -n "$WIN_X" && -n "$WIN_Y" && -n "$WIN_W" && -n "$WIN_H" ]]; then
                return 0
            fi
        fi

        if (( attempt < attempts )); then
            sleep "$delay_seconds"
        fi
    done

    ws_log "ERROR: unable to read window geometry."
    ws_permissions_hint
    return 1
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

ws_get_window_id() {
    WIN_ID="$(
        swift - <<'SWIFT'
import CoreGraphics
import Foundation

let ownerCandidates: Set<String> = ["Workspaces", "WorkspaceManager"]
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

for window in windows {
    let owner = window[kCGWindowOwnerName as String] as? String ?? ""
    let layer = window[kCGWindowLayer as String] as? Int ?? 1
    guard ownerCandidates.contains(owner), layer == 0 else { continue }

    if let windowID = window[kCGWindowNumber as String] as? Int {
        print(windowID)
        exit(0)
    }
}

exit(1)
SWIFT
    )" || {
        ws_log "ERROR: unable to read WorkspaceManager window id."
        ws_permissions_hint
        return 1
    }

    if [[ ! "$WIN_ID" =~ ^[0-9]+$ ]]; then
        ws_log "ERROR: invalid window id output: '$WIN_ID'"
        return 1
    fi
}

ws_take_window_screenshot() {
    local name="$1"
    local path="$ARTIFACT_DIR/${name}.png"

    if ! ws_get_window_id; then
        ws_log "WARN: falling back to full-screen capture."
        ws_take_screenshot "$name"
        return
    fi

    if ! screencapture -x -l "$WIN_ID" "$path"; then
        ws_log "ERROR: window screenshot capture failed ($path)"
        ws_log "WARN: falling back to full-screen capture."
        ws_take_screenshot "$name"
    fi
}

ws_print_artifacts() {
    ws_log "Artifacts saved to: $ARTIFACT_DIR"
    ls -la "$ARTIFACT_DIR"
}
