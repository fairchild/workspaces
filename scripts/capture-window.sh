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
#   ./scripts/capture-window.sh --pid 12345 --output ./output/window/custom.png
#   ./scripts/capture-window.sh --activate
#
# ==========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="WorkspaceManager"
INSTALLED_APP_BINARY="/Applications/$APP_NAME.app/Contents/MacOS/$APP_NAME"
DEFAULT_OUTPUT_DIR="$REPO_ROOT/output/window"
OUTPUT_PATH=""
ACTIVATE_APP=false
TARGET_PID=""
LATEST_PATH=""
CAPTURE_RETRIES=5
CAPTURE_RETRY_DELAY_SECONDS=1

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
  --pid <pid>          Capture only a window owned by this process id
  --activate           Activate WorkspaceManager before capture
  --help, -h           Show this help

Notes:
- Default mode avoids app activation to reduce focus contention on shared desktops.
- Requires Screen Recording permission for this terminal.
- Uses CoreGraphics window enumeration for window-id lookup (no Accessibility dependency).
- Use --pid when multiple WorkSpaces/WorkspaceManager debug windows may be visible.
- `--activate` uses System Events to focus a running process and never launches by bundle id.
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
            --pid)
                [[ $# -ge 2 ]] || fail "--pid requires a value"
                [[ "$2" =~ ^[0-9]+$ ]] || fail "--pid must be a process id"
                TARGET_PID="$2"
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
    if [[ -n "$TARGET_PID" ]]; then
        kill -0 "$TARGET_PID" 2>/dev/null || fail "target pid is not running: $TARGET_PID"
    fi
    if pgrep -f "$INSTALLED_APP_BINARY" >/dev/null 2>&1; then
        fail "Installed app process detected at $INSTALLED_APP_BINARY; quit it before capture"
    fi
    if [[ "$ACTIVATE_APP" == true ]]; then
        command -v osascript >/dev/null 2>&1 || fail "osascript is required for --activate"
    fi
}

activate_if_requested() {
    if [[ "$ACTIVATE_APP" == true ]]; then
        log "Capture mode: interactive (--activate)"
        osascript -e 'tell application "System Events" to set frontmost of process "WorkspaceManager" to true' >/dev/null 2>&1 \
            || fail "could not activate $APP_NAME"
        sleep 0.2
    else
        log "Capture mode: shared-desktop-safe (no activation)"
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
        WORKSPACES_CAPTURE_OWNER_PID="$TARGET_PID" \
        swift - <<'SWIFT'
import CoreGraphics
import Foundation

let ownerCandidates: Set<String> = ["WorkSpaces", "WorkspaceManager"]
let targetPID = Int(ProcessInfo.processInfo.environment["WORKSPACES_CAPTURE_OWNER_PID"] ?? "")
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

for window in windows {
    let owner = window[kCGWindowOwnerName as String] as? String ?? ""
    let layer = window[kCGWindowLayer as String] as? Int ?? 1
    guard ownerCandidates.contains(owner), layer == 0 else { continue }
    if let targetPID {
        let ownerPID = window[kCGWindowOwnerPID as String] as? Int ?? -1
        guard ownerPID == targetPID else { continue }
    }

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

main() {
    parse_args "$@"
    resolve_output_paths
    ensure_dependencies
    activate_if_requested
    if [[ -n "$TARGET_PID" ]]; then
        log "Capture target pid: $TARGET_PID"
    fi

    local attempt win_id
    for ((attempt = 1; attempt <= CAPTURE_RETRIES; attempt++)); do
        win_id="$(read_window_id)"
        if screencapture -x -l "$win_id" "$OUTPUT_PATH"; then
            if [[ "$OUTPUT_PATH" != "$LATEST_PATH" ]]; then
                cp "$OUTPUT_PATH" "$LATEST_PATH"
            fi
            log "Captured window id $win_id"
            log "Screenshot: $OUTPUT_PATH"
            log "Latest: $LATEST_PATH"
            return 0
        fi

        if (( attempt < CAPTURE_RETRIES )); then
            log "Capture attempt $attempt/$CAPTURE_RETRIES failed for window id $win_id; retrying..."
            sleep "$CAPTURE_RETRY_DELAY_SECONDS"
        fi
    done

    fail "window capture failed after $CAPTURE_RETRIES attempts"
}

main "$@"
