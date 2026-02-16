#!/bin/bash
# Primary screenshot-focused UI flow capture for WorkspaceManager.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/ui-test-common.sh
source "$SCRIPT_DIR/lib/ui-test-common.sh"

ws_prepare_artifacts "workspaces-ui-capture"
ws_register_cleanup_trap

ws_log "=== WorkspaceManager UI Capture Test ==="
ws_kill_existing
ws_require_cmd swift
ws_require_cmd osascript
ws_require_cmd cliclick
ws_require_cmd screencapture

ws_build_app
ws_launch_app 5

ws_take_screenshot "01-launched"
ws_activate_app
ws_take_screenshot "02-activated"

ws_get_window_geometry
ws_compute_click_points
ws_log "Window geometry: x=$WIN_X y=$WIN_Y w=$WIN_W h=$WIN_H"
ws_log "Terminal click target: x=$TERMINAL_X y=$TERMINAL_Y"

ws_click "$TERMINAL_X" "$TERMINAL_Y"
ws_take_screenshot "03-terminal-clicked"

ws_type "echo WORKSPACES_UI_CAPTURE"
ws_take_screenshot "04-after-typing"

ws_press_enter
ws_take_screenshot "05-after-enter"

ws_type "pwd"
ws_press_enter
ws_take_screenshot "06-after-pwd"

ws_log "Stopping app..."
ws_stop_app

ws_log "=== Test Complete ==="
ws_print_artifacts
ws_log "Screenshot files:"
ls -la "$ARTIFACT_DIR"/*.png
