#!/bin/bash
# ==========================================================================
# capture-window.sh - Capture WorkspaceManager window without foreground steal
# ==========================================================================
#
# This script captures the current WorkspaceManager window by window id
# (`screencapture -l`) and does not activate the app unless explicitly asked.
#
# Usage:
#   ./scripts/capture-window.sh
#   ./scripts/capture-window.sh --output ./output/window/custom.png
#   ./scripts/capture-window.sh --activate
#
# ==========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="WorkspaceManager"
APP_BUNDLE_ID="com.cloudcompute.workspaces"
DEFAULT_OUTPUT_DIR="$REPO_ROOT/output/window"
OUTPUT_PATH=""
ACTIVATE_APP=false
LATEST_PATH=""

log() {
    echo "[$(date +%H:%M:%S)] $*"
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
Usage: ./scripts/capture-window.sh [options]

Options:
  --output <path>      Output png path (default: ./output/window/window-<timestamp>.png)
  --activate           Activate WorkspaceManager before capture
  --help, -h           Show this help

Notes:
- Default mode avoids app activation to reduce focus contention on shared desktops.
- Requires Screen Recording permission for this terminal.
- Uses CoreGraphics window enumeration for window-id lookup (no Accessibility dependency).
USAGE
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output)
                [[ $# -ge 2 ]] || fail "--output requires a value"
                OUTPUT_PATH="$2"
                shift 2
                ;;
            --activate)
                ACTIVATE_APP=true
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

ensure_dependencies() {
    command -v swift >/dev/null 2>&1 || fail "swift is required"
    command -v screencapture >/dev/null 2>&1 || fail "screencapture is required"
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || fail "$APP_NAME is not running"
    if [[ "$ACTIVATE_APP" == true ]]; then
        command -v osascript >/dev/null 2>&1 || fail "osascript is required for --activate"
    fi
}

activate_if_requested() {
    if [[ "$ACTIVATE_APP" == true ]]; then
        osascript -e "tell application id \"$APP_BUNDLE_ID\" to activate" >/dev/null 2>&1 \
            || fail "could not activate $APP_NAME"
        sleep 0.2
    fi
}

resolve_output_paths() {
    if [[ -z "$OUTPUT_PATH" ]]; then
        mkdir -p "$DEFAULT_OUTPUT_DIR"
        OUTPUT_PATH="$DEFAULT_OUTPUT_DIR/window-$(date +%Y%m%d-%H%M%S).png"
    fi

    local output_dir
    output_dir="$(cd "$(dirname "$OUTPUT_PATH")" && pwd)"
    OUTPUT_PATH="$output_dir/$(basename "$OUTPUT_PATH")"
    mkdir -p "$output_dir"

    LATEST_PATH="$output_dir/latest.png"
}

read_window_id() {
    local win_id
    win_id="$(
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
    )" || fail "unable to find a visible $APP_NAME window id"

    if [[ ! "$win_id" =~ ^[0-9]+$ ]]; then
        fail "unable to determine a valid $APP_NAME window id"
    fi

    echo "$win_id"
}

capture_window() {
    local win_id="$1"
    screencapture -x -l "$win_id" "$OUTPUT_PATH" || fail "window capture failed"

    if [[ "$OUTPUT_PATH" != "$LATEST_PATH" ]]; then
        cp "$OUTPUT_PATH" "$LATEST_PATH"
    fi
}

main() {
    parse_args "$@"
    resolve_output_paths
    ensure_dependencies
    activate_if_requested

    local win_id
    win_id="$(read_window_id)"

    capture_window "$win_id"

    log "Captured window id $win_id"
    log "Screenshot: $OUTPUT_PATH"
    log "Latest: $LATEST_PATH"
}

main "$@"
