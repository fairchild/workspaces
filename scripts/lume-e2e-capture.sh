#!/bin/bash
# Automated Lume first-use setup and workspace creation capture for WorkspaceManager.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/ui-test-common.sh
source "$SCRIPT_DIR/lib/ui-test-common.sh"

OUTPUT_ROOT="$REPO_ROOT/output/lume-e2e"
RUN_STAMP="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$OUTPUT_ROOT/$RUN_STAMP"
LATEST_LINK="$OUTPUT_ROOT/latest"
WORKSPACE_NAME="lume-e2e-${RUN_STAMP##*-}"
TARGET_PID=""

mkdir -p "$RUN_DIR"

ws_prepare_artifacts "workspaces-lume-e2e"
ws_register_cleanup_trap

log_path="$RUN_DIR/run.log"
exec > >(tee "$log_path") 2>&1

capture_window() {
    local name="$1"
    local window_id

    ws_activate_app
    TARGET_PID="$(pgrep -xn WorkspaceManager)"
    if [[ -z "$TARGET_PID" ]]; then
        ws_log "ERROR: could not resolve WorkspaceManager pid for screenshot capture."
        return 1
    fi

    window_id="$(
        TARGET_PID="$TARGET_PID" swift - <<'SWIFT'
import CoreGraphics
import Foundation

let targetPID = Int32(ProcessInfo.processInfo.environment["TARGET_PID"] ?? "") ?? 0
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] ?? []

let matchingWindows = windows.compactMap { window -> (id: Int, layer: Int, area: Double)? in
    let ownerPID = window[kCGWindowOwnerPID as String] as? Int32 ?? -1
    let layer = window[kCGWindowLayer as String] as? Int ?? 1
    guard ownerPID == targetPID, layer == 0 else { return nil }

    let windowID = window[kCGWindowNumber as String] as? Int ?? 0
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let width = bounds["Width"] as? Double ?? 0
    let height = bounds["Height"] as? Double ?? 0
    return (windowID, layer, width * height)
}

if let bestWindow = matchingWindows.max(by: { $0.area < $1.area }) {
    print(bestWindow.id)
    exit(0)
}

exit(1)
SWIFT
    )" || {
        ws_log "ERROR: unable to resolve WorkspaceManager window id via CoreGraphics."
        return 1
    }

    if ! screencapture -x -l "$window_id" "$RUN_DIR/${name}.png"; then
        ws_log "ERROR: screencapture failed for WorkspaceManager window id $window_id."
        return 1
    fi
}

press_command_a() {
    osascript -e 'tell application "System Events" to keystroke "a" using command down' >/dev/null
    sleep 0.2
}

write_evidence_summary() {
    cat >"$RUN_DIR/EVIDENCE.md" <<EOF
# Lume E2E Evidence

- Timestamp: $RUN_STAMP
- Mode: deterministic UI fixture
- Command: \`./scripts/lume-e2e-capture.sh\`
- Workspace name: \`$WORKSPACE_NAME\`
- Host match shown in UI: Tahoe 26.2 + Xcode 26.2

Artifacts:
- \`01-new-workspace-sheet.png\` — environment picker with \`macOS VM\`
- \`02-macos-vm-selected.png\` — \`macOS VM\` selected before create
- \`03-lume-setup-confirmation.png\` — one-click install confirmation
- \`04-lume-setup-progress.png\` — setup progress sheet
- \`05-workspace-created.png\` — workspace created after automatic resume
EOF
}

ws_log "=== WorkspaceManager Lume E2E Capture ==="
ws_kill_existing
ws_require_cmd swift
ws_require_cmd osascript
ws_require_cmd cliclick
ws_require_cmd screencapture

export WORKSPACES_UI_FIXTURE=1
export WORKSPACES_UI_FIXTURE_LUME_E2E=1
export WORKSPACES_UI_FIXTURE_LUME_STEP_DELAY_MS=700
export WORKSPACES_DISABLE_AUTO_IMPORT=1

ws_build_app
ws_launch_app 8
ws_activate_app
ws_log "Waiting for fixture provider availability..."
sleep 2

cp "$APP_LOG" "$RUN_DIR/app-output-initial.log" 2>/dev/null || true

ws_log "Opening New Workspace sheet via File > New Workspace..."
osascript <<'APPLESCRIPT'
tell application "System Events"
    tell process "WorkspaceManager"
        set frontmost to true
        click menu item "New Workspace..." of menu "File" of menu bar 1
    end tell
end tell
APPLESCRIPT

sleep 2
ws_log "Replacing suggested workspace name with $WORKSPACE_NAME..."
ws_activate_app
press_command_a
ws_type "$WORKSPACE_NAME"

capture_window "01-new-workspace-sheet"

ws_log "Confirming fixture selected macOS VM by default..."
sleep 1
capture_window "02-macos-vm-selected"

ws_log "Creating macOS VM workspace to trigger Lume setup..."
ws_activate_app
ws_press_enter
sleep 2
capture_window "03-lume-setup-confirmation"

ws_log "Confirming Lume setup..."
ws_activate_app
ws_press_enter
sleep 1
capture_window "04-lume-setup-progress"

ws_log "Waiting for automatic resume and workspace creation..."
sleep 8
capture_window "05-workspace-created"

cp "$APP_LOG" "$RUN_DIR/app-output-final.log" 2>/dev/null || true
write_evidence_summary

ln -sfn "$RUN_DIR" "$LATEST_LINK"

ws_log "Stopping app..."
ws_stop_app

ws_log "Artifacts copied to: $RUN_DIR"
ls -la "$RUN_DIR"
