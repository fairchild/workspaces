#!/bin/bash
# Deterministic left-sidebar screenshot capture for fast UI iteration.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/ui-test-common.sh
source "$SCRIPT_DIR/lib/ui-test-common.sh"

OUTPUT_DIR="$REPO_ROOT/output/sidebar"
LATEST_CAPTURE="$OUTPUT_DIR/latest.png"

ws_prepare_artifacts "workspaces-sidebar-capture"
ws_register_cleanup_trap

ws_log "=== WorkspaceManager Sidebar Capture ==="
ws_kill_existing
ws_require_cmd swift
ws_require_cmd osascript
ws_require_cmd screencapture

mkdir -p "$OUTPUT_DIR"

# Launch with stable in-memory fixture data and no auto-import noise.
export WORKSPACES_UI_FIXTURE=1
export WORKSPACES_DISABLE_AUTO_IMPORT=1

ws_build_app
ws_launch_app 4
ws_activate_app
ws_take_window_screenshot "sidebar-window"

cp "$ARTIFACT_DIR/sidebar-window.png" "$LATEST_CAPTURE"
cp "$ARTIFACT_DIR/sidebar-window.png" "$OUTPUT_DIR/sidebar-$(date +%Y%m%d-%H%M%S).png"

ws_log "Stopping app..."
ws_stop_app

ws_log "=== Capture Complete ==="
ws_print_artifacts
ws_log "Latest sidebar capture: $LATEST_CAPTURE"
ls -la "$OUTPUT_DIR"/*.png
