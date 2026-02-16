#!/bin/bash
# Primary fast UI smoke test for WorkspaceManager terminal interaction.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/ui-test-common.sh
source "$SCRIPT_DIR/lib/ui-test-common.sh"

ws_prepare_artifacts "workspaces-ui-smoke"
ws_register_cleanup_trap

ws_log "=== WorkspaceManager UI Smoke Test ==="
ws_kill_existing
ws_require_cmd swift
ws_require_cmd osascript
ws_require_cmd cliclick

ws_build_app
ws_launch_app 5
ws_activate_app
ws_get_window_geometry
ws_compute_click_points

ws_log "Window geometry: x=$WIN_X y=$WIN_Y w=$WIN_W h=$WIN_H"
ws_log "Terminal click target: x=$TERMINAL_X y=$TERMINAL_Y"

ws_click "$TERMINAL_X" "$TERMINAL_Y"
ws_type "echo WORKSPACES_UI_SMOKE"
ws_press_enter
ws_type "pwd"
ws_press_enter

ws_log "Stopping app..."
ws_stop_app

ws_log "=== Test Complete ==="
ws_print_artifacts
ws_log "App log tail:"
tail -n 30 "$APP_LOG" || true
