#!/bin/bash
# ==========================================================================
# settings-window-smoke.sh - Verify Settings opens from real macOS commands
# ==========================================================================
#
# Drives the actual user-facing Settings entry points:
#   1) Cmd+,
#   2) WorkSpaces -> Settings...
#
# Pass/fail is semantic: after each trigger, the script waits for the Settings
# scene's accessibility identifier (`settings.root`) in the debug app process.
# Screenshots are captured only as supporting evidence.
#
# This is intentionally activation-driving and is not shared-desktop-safe.
#
# ==========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CAPTURE_SCRIPT="$REPO_ROOT/scripts/capture-window.sh"
DEBUG_BINARY="$REPO_ROOT/.build/arm64-apple-macosx/debug/WorkspaceManager"
GHOSTTYKIT_FRAMEWORK="$REPO_ROOT/Frameworks/GhosttyKit.xcframework"
INSTALLED_BINARY_CANDIDATES=(
    "/Applications/WorkSpaces.app/Contents/MacOS/WorkspaceManager"
    "/Applications/WorkspaceManager.app/Contents/MacOS/WorkspaceManager"
)

MODE="both"
BUILD_BEFORE_LAUNCH=false
TRUST_MISE=false
AX_IDENTIFIER="settings.root"
OUTPUT_DIR="$REPO_ROOT/output/settings-window-smoke/$(date +%Y%m%d-%H%M%S)"
DATA_DIR="$REPO_ROOT/.dev-data/workspacemanager-settings-smoke"
APP_PID=""

usage() {
    cat <<'USAGE'
Usage: ./scripts/settings-window-smoke.sh [options]

Options:
  --mode <both|shortcut|menu>  Entry point(s) to verify (default: both)
  --build                     Build before launch (default: reuse current debug binary)
  --trust-mise                Accepted for compatibility; this script launches the debug binary directly
  --output-dir <path>         Artifact directory (default: ./output/settings-window-smoke/<timestamp>)
  --help, -h                  Show this help

Notes:
- This script activates WorkSpaces and sends keyboard/menu input.
- Requires Accessibility + Automation permissions for this terminal.
- The assertion uses AXIdentifier=settings.root; screenshots are supporting evidence only.
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
            --mode)
                [[ $# -ge 2 ]] || fail "--mode requires a value"
                MODE="$2"
                case "$MODE" in
                    both|shortcut|menu) ;;
                    *) fail "--mode must be one of: both, shortcut, menu" ;;
                esac
                shift 2
                ;;
            --build)
                BUILD_BEFORE_LAUNCH=true
                shift
                ;;
            --trust-mise)
                TRUST_MISE=true
                shift
                ;;
            --output-dir)
                [[ $# -ge 2 ]] || fail "--output-dir requires a value"
                OUTPUT_DIR="$2"
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

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

permissions_hint() {
    cat >&2 <<'EOF'
Permission requirements:
  1) Accessibility access for the invoking terminal
  2) Automation access to System Events
  3) Screen Recording for screenshot artifacts

Enable permissions in System Settings -> Privacy & Security.
EOF
}

ensure_no_installed_app_instance() {
    local binary
    for binary in "${INSTALLED_BINARY_CANDIDATES[@]}"; do
        if pgrep -f "$binary" >/dev/null 2>&1; then
            fail "installed app process detected at $binary; quit it before running settings smoke"
        fi
    done
}

build_if_requested() {
    if [[ "$BUILD_BEFORE_LAUNCH" != true ]]; then
        [[ -x "$DEBUG_BINARY" ]] || fail "debug binary not found: $DEBUG_BINARY; rerun with --build"
        return
    fi

    if [[ ! -d "$GHOSTTYKIT_FRAMEWORK" ]]; then
        log "Building GhosttyKit.xcframework..."
        (
            cd "$REPO_ROOT"
            ./scripts/build-ghosttykit.sh
        )
    fi

    log "Building WorkspaceManager..."
    (
        cd "$REPO_ROOT"
        swift build
    )
}

stop_app() {
    if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
    fi
    APP_PID=""
}

cleanup() {
    stop_app
}

launch_debug_app() {
    mkdir -p "$OUTPUT_DIR"

    local launch_output="$OUTPUT_DIR/launch-$1.log"
    if [[ "$TRUST_MISE" == true ]]; then
        log "Note: --trust-mise is not needed for direct debug-binary launch."
    fi

    ensure_no_installed_app_instance
    log "Launching debug app for $1 path..."
    mkdir -p "$DATA_DIR"
    (
        cd "$REPO_ROOT"
        exec env \
            WORKSPACES_DATA_DIR="$DATA_DIR" \
            WORKSPACES_APP_VARIANT=dev \
            "$DEBUG_BINARY"
    ) >"$launch_output" 2>&1 &
    APP_PID=$!

    wait_for_app_window "$1" "$launch_output"
    log "Debug app pid for $1 path: $APP_PID"
}

wait_for_app_window() {
    local mode_name="$1"
    local launch_output="$2"
    local attempt

    for attempt in {1..40}; do
        if ! kill -0 "$APP_PID" 2>/dev/null; then
            tail -n 80 "$launch_output" >&2 || true
            fail "debug app exited before $mode_name path could run"
        fi

        if swift - "$APP_PID" <<'SWIFT' >/dev/null 2>&1
import CoreGraphics
import Foundation

guard CommandLine.arguments.count >= 2, let targetPID = Int(CommandLine.arguments[1]) else {
    exit(2)
}

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

for window in windows {
    let ownerPID = window[kCGWindowOwnerPID as String] as? Int ?? -1
    let layer = window[kCGWindowLayer as String] as? Int ?? 1
    guard ownerPID == targetPID, layer == 0 else { continue }
    exit(0)
}

exit(1)
SWIFT
        then
            return
        fi

        sleep 0.25
    done

    tail -n 80 "$launch_output" >&2 || true
    fail "debug app did not open a visible window for $mode_name path"
}

activate_app() {
    if ! osascript - "$APP_PID" <<'APPLESCRIPT' >/dev/null 2>&1
on run argv
    set targetPID to item 1 of argv as integer
    tell application "System Events"
        set targetProcess to first process whose unix id is targetPID
        set frontmost of targetProcess to true
    end tell
end run
APPLESCRIPT
    then
        permissions_hint
        fail "could not activate WorkspaceManager pid=$APP_PID"
    fi
    sleep 0.4
}

trigger_shortcut() {
    log "Triggering Settings with Cmd+,"
    if ! osascript - "$APP_PID" <<'APPLESCRIPT' >/dev/null 2>&1
on run argv
    set targetPID to item 1 of argv as integer
    tell application "System Events"
        set targetProcess to first process whose unix id is targetPID
        set frontmost of targetProcess to true
        keystroke "," using command down
    end tell
end run
APPLESCRIPT
    then
        permissions_hint
        fail "failed sending Cmd+,"
    fi
}

trigger_menu() {
    log "Triggering Settings through app menu"
    local error_output="$OUTPUT_DIR/menu-trigger-error.log"
    if ! osascript - "$APP_PID" <<'APPLESCRIPT' >/dev/null 2>"$error_output"
on run argv
set targetPID to item 1 of argv as integer
tell application "System Events"
    set targetProcess to first process whose unix id is targetPID
    tell targetProcess
        set frontmost of targetProcess to true
        delay 0.2
        set appMenuBarItem to missing value
        set menuBarItemNames to {}
        repeat with candidateMenuBarItem in menu bar items of menu bar 1
            try
                set candidateMenuBarItemName to name of candidateMenuBarItem as text
            on error
                set candidateMenuBarItemName to "<unnamed>"
            end try
            copy candidateMenuBarItemName to end of menuBarItemNames
            if candidateMenuBarItemName starts with "Workspace" or candidateMenuBarItemName starts with "WorkSpaces" then
                set appMenuBarItem to candidateMenuBarItem
                exit repeat
            end if
        end repeat
        if appMenuBarItem is missing value then error "WorkspaceManager app menu not found; menu bar items: " & menuBarItemNames
        click appMenuBarItem
        delay 0.1
        set appMenu to menu 1 of appMenuBarItem
        set settingsItems to {}
        set appMenuItemNames to {}
        repeat with candidate in menu items of appMenu
            try
                set candidateName to name of candidate as text
            on error
                set candidateName to "<unnamed>"
            end try
            copy candidateName to end of appMenuItemNames
            if candidateName starts with "Settings" then
                copy candidate to end of settingsItems
            end if
        end repeat
        set settingsCount to count of settingsItems
        if settingsCount is not 1 then error "Expected exactly one Settings menu item, found " & settingsCount & "; app menu items: " & appMenuItemNames
        click item 1 of settingsItems
    end tell
end tell
end run
APPLESCRIPT
    then
        if [[ -s "$error_output" ]]; then
            sed 's/^/[osascript] /' "$error_output" >&2
        fi
        permissions_hint
        fail "failed choosing Settings from app menu"
    fi
}

wait_for_settings_identifier() {
    local mode_name="$1"
    swift - "$APP_PID" "$AX_IDENTIFIER" 8 <<'SWIFT'
import ApplicationServices
import Foundation

let args = CommandLine.arguments
guard args.count >= 4, let pidValue = Int32(args[1]), let timeout = Double(args[3]) else {
    fputs("usage: ax-probe <pid> <identifier> <timeout>\n", stderr)
    exit(2)
}

let targetIdentifier = args[2]
let app = AXUIElementCreateApplication(pidValue)
let deadline = Date().addingTimeInterval(timeout)

func copyAttribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    guard result == .success else { return nil }
    return value
}

func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
    copyAttribute(element, name) as? String
}

func childElements(of element: AXUIElement) -> [AXUIElement] {
    let candidateAttributes = [
        kAXChildrenAttribute as String,
        kAXContentsAttribute as String,
        kAXTabsAttribute as String,
        kAXRowsAttribute as String,
        kAXColumnsAttribute as String,
    ]

    var children: [AXUIElement] = []
    for attribute in candidateAttributes {
        if let elements = copyAttribute(element, attribute) as? [AXUIElement] {
            children.append(contentsOf: elements)
        }
    }
    return children
}

func containsIdentifier(_ element: AXUIElement, depth: Int = 0) -> Bool {
    guard depth < 48 else { return false }

    if stringAttribute(element, "AXIdentifier") == targetIdentifier {
        return true
    }

    for child in childElements(of: element) {
        if containsIdentifier(child, depth: depth + 1) {
            return true
        }
    }

    return false
}

func settingsWindowExists() -> Bool {
    guard let windows = copyAttribute(app, kAXWindowsAttribute as String) as? [AXUIElement] else {
        return false
    }

    for window in windows {
        if containsIdentifier(window) {
            return true
        }
    }

    return false
}

while Date() < deadline {
    if settingsWindowExists() {
        print("found AXIdentifier=\(targetIdentifier)")
        exit(0)
    }
    Thread.sleep(forTimeInterval: 0.2)
}

fputs("timed out waiting for AXIdentifier=\(targetIdentifier)\n", stderr)
exit(1)
SWIFT
    local status=$?
    if [[ "$status" -ne 0 ]]; then
        permissions_hint
        fail "Settings window did not expose AXIdentifier=$AX_IDENTIFIER for $mode_name path"
    fi
}

capture_settings_window() {
    local mode_name="$1"
    local output="$OUTPUT_DIR/settings-$mode_name.png"

    if "$CAPTURE_SCRIPT" --pid "$APP_PID" --output "$output" >/dev/null 2>&1; then
        log "Screenshot for $mode_name path: $output"
    else
        log "Warning: semantic validation passed, but screenshot capture failed for $mode_name path."
    fi
}

run_one_path() {
    local mode_name="$1"

    launch_debug_app "$mode_name"
    activate_app

    case "$mode_name" in
        shortcut) trigger_shortcut ;;
        menu) trigger_menu ;;
        *) fail "internal error: unknown mode $mode_name" ;;
    esac

    wait_for_settings_identifier "$mode_name"
    log "Settings window semantic assertion passed for $mode_name path."
    capture_settings_window "$mode_name"
    stop_app
}

main() {
    parse_args "$@"
    require_cmd swift
    require_cmd osascript
    require_cmd pgrep
    require_cmd sed
    build_if_requested

    mkdir -p "$OUTPUT_DIR"
    trap cleanup EXIT

    case "$MODE" in
        shortcut)
            run_one_path shortcut
            ;;
        menu)
            run_one_path menu
            ;;
        both)
            run_one_path shortcut
            run_one_path menu
            ;;
    esac

    log "Settings window smoke passed."
    log "Artifacts: $OUTPUT_DIR"
}

main "$@"
