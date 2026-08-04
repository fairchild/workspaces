#!/bin/bash
# ==========================================================================
# shortcut-pass-through-smoke.sh - Shortcut pass-through smoke for Ghostty
# ==========================================================================
#
# Verifies that non-app-owned shortcut chords pass through to Ghostty by:
# 1) Launching the debug binary
# 2) Focusing terminal area
# 3) Sending Cmd+D, Cmd+[ and Cmd+]
# 4) Checking launch log for new_split / goto_split runtime actions
#
# =======================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEBUG_BINARY="$REPO_ROOT/.build/arm64-apple-macosx/debug/WorkspaceManager"
INSTALLED_APP_BINARY="/Applications/WorkSpaces.app/Contents/MacOS/WorkspaceManager"
BUNDLE_ID="com.cloudcompute.workspaces"
GHOSTTY_MANAGED_MODE="ghostty_managed_splits"

BUILD_BEFORE_LAUNCH=false

usage() {
    cat <<'USAGE'
Usage: ./scripts/shortcut-pass-through-smoke.sh [options]

Options:
  --build     Build before launch (default: reuse existing debug binary)
  --help, -h  Show this help

Notes:
- This script activates WorkspaceManager and sends keyboard input.
- Requires Accessibility + Automation permissions for this terminal.
- Requires Terminal Multiplexing Mode = Ghostty Splits; tmux mode is intentionally unsupported here.
USAGE
}

log() {
    echo "[$(date +%H:%M:%S)] $*"
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --build)
                BUILD_BEFORE_LAUNCH=true
                shift
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

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

ensure_clean_process_space() {
    if pgrep -f "$INSTALLED_APP_BINARY" >/dev/null 2>&1; then
        fail "installed app is running ($INSTALLED_APP_BINARY); quit it before shortcut smoke"
    fi
}

require_ghostty_managed_mode() {
    local mode
    mode="$(defaults read "$BUNDLE_ID" terminalMultiplexingMode 2>/dev/null || true)"
    if [[ -z "$mode" ]]; then
        mode="$GHOSTTY_MANAGED_MODE"
    fi

    if [[ "$mode" != "$GHOSTTY_MANAGED_MODE" ]]; then
        fail "shortcut smoke requires Ghostty Splits mode; current terminalMultiplexingMode is '$mode'. Switch the app setting before running this script."
    fi
}

launch_debug_app() {
    local launch_args=(--no-build)
    if [[ "$BUILD_BEFORE_LAUNCH" == true ]]; then
        launch_args=()
    fi

    (
        cd "$REPO_ROOT"
        ./scripts/launch-dev.sh "${launch_args[@]}"
    )
}

latest_launch_log() {
    ls -1t "$REPO_ROOT"/.dev-data/logs/launch-dev-*.log | head -n 1
}

window_click_coordinates() {
    swift - <<'SWIFT'
import CoreGraphics
import Foundation

let ownerCandidates: Set<String> = ["WorkSpaces", "WorkspaceManager"]
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

for window in windows {
    let owner = window[kCGWindowOwnerName as String] as? String ?? ""
    let layer = window[kCGWindowLayer as String] as? Int ?? 1
    guard ownerCandidates.contains(owner), layer == 0 else { continue }

    guard
        let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
        let x = bounds["X"],
        let y = bounds["Y"],
        let width = bounds["Width"],
        let height = bounds["Height"]
    else {
        continue
    }

    // Bias into the primary terminal pane, clear of sidebar and right pane.
    let clickX = Int(x + (width * 0.58))
    let clickY = Int(y + (height * 0.52))
    print("\(clickX),\(clickY)")
    exit(0)
}

exit(1)
SWIFT
}

activate_and_focus_terminal() {
    osascript -e 'tell application "System Events" to set frontmost of process "WorkspaceManager" to true' >/dev/null 2>&1 \
        || fail "unable to activate WorkspaceManager"

    local coords
    coords="$(window_click_coordinates)" || fail "unable to resolve WorkspaceManager window coordinates"
    cliclick "c:$coords" >/dev/null 2>&1 || fail "unable to click terminal target"
}

send_shortcuts() {
    osascript -e 'tell application "System Events" to keystroke "d" using command down' >/dev/null 2>&1 \
        || fail "failed sending Cmd+D"
    sleep 0.35
    osascript -e 'tell application "System Events" to keystroke "[" using command down' >/dev/null 2>&1 \
        || fail "failed sending Cmd+["
    sleep 0.25
    osascript -e 'tell application "System Events" to keystroke "]" using command down' >/dev/null 2>&1 \
        || fail "failed sending Cmd+]"
}

verify_log_evidence() {
    local log_file="$1"

    if ! rg -q '\[GhosttyAppManager\] action=new_split direction=' "$log_file"; then
        tail -n 120 "$log_file" >&2 || true
        fail "missing new_split evidence in log: $log_file"
    fi

    if ! rg -q '\[GhosttyAppManager\] action=goto_split direction=' "$log_file"; then
        tail -n 120 "$log_file" >&2 || true
        fail "missing goto_split evidence in log: $log_file"
    fi
}

main() {
    parse_args "$@"

    require_cmd swift
    require_cmd rg
    require_cmd osascript
    require_cmd cliclick

    ensure_clean_process_space
    require_ghostty_managed_mode
    launch_debug_app
    ensure_clean_process_space

    local log_file
    log_file="$(latest_launch_log)"
    [[ -n "$log_file" ]] || fail "no launch-dev log found"

    activate_and_focus_terminal

    # App logging is os.Logger, which never reaches the launch-dev stdout log;
    # capture the unified log stream (--level info required) for evidence.
    local stream_log
    stream_log="$(mktemp -t shortcut-smoke-stream)"
    /usr/bin/log stream --predicate 'subsystem == "com.cloudcompute.workspaces"' \
        --level info --style compact > "$stream_log" 2>/dev/null &
    local stream_pid=$!
    sleep 1

    send_shortcuts
    sleep 0.8
    kill "$stream_pid" 2>/dev/null || true
    wait "$stream_pid" 2>/dev/null || true
    verify_log_evidence "$stream_log"

    log "Shortcut pass-through smoke passed"
    log "Evidence log: $stream_log (unified log stream; launcher log: $log_file)"
}

main "$@"
