#!/bin/bash
# Test terminal initialization timing

set -e

SCREENSHOT_DIR="/tmp/terminal-init-test"
mkdir -p "$SCREENSHOT_DIR"
rm -f "$SCREENSHOT_DIR"/*

log() {
    echo "[$(date +%H:%M:%S)] $1"
}

cleanup() {
    pkill -f "WorkspaceManager" 2>/dev/null || true
}
trap cleanup EXIT

log "=== Terminal Init Test ==="

pkill -f "WorkspaceManager" 2>/dev/null || true
sleep 1

log "Building..."
cd "$(dirname "$0")/.." # repo root
swift build 2>&1 | grep -E "(error|Build complete)" || true

log "Launching..."
swift run > "$SCREENSHOT_DIR/app.log" 2>&1 &
APP_PID=$!
sleep 4

# Position window
osascript -e 'tell application "System Events" to tell process "WorkspaceManager" to set position of window 1 to {50, 50}'
osascript -e 'tell application "System Events" to set frontmost of process "WorkspaceManager" to true'
sleep 0.5

screencapture -x "$SCREENSHOT_DIR/01-launched.png"

# Click on workspace (lower in sidebar)
log "Selecting workspace..."
cliclick c:150,250
sleep 0.5
screencapture -x "$SCREENSHOT_DIR/02-workspace-clicked.png"

# Wait for terminal to fully initialize
log "Waiting 3s for terminal to initialize..."
sleep 3
screencapture -x "$SCREENSHOT_DIR/03-after-3s-wait.png"

# Now click in terminal
log "Clicking in terminal area..."
cliclick c:400,400
sleep 0.5
screencapture -x "$SCREENSHOT_DIR/04-terminal-clicked.png"

# Wait a bit more
sleep 1

# Try typing
log "Attempting to type..."
cliclick t:"ls"
sleep 0.5
screencapture -x "$SCREENSHOT_DIR/05-after-type.png"

osascript -e 'tell application "System Events" to key code 36'
sleep 2
screencapture -x "$SCREENSHOT_DIR/06-after-enter.png"

log ""
log "=== App Logs ==="
cat "$SCREENSHOT_DIR/app.log" | grep -v "^Building\|^Build\|\[0/" | tail -30

log ""
log "=== Screenshots ==="
ls -la "$SCREENSHOT_DIR"/*.png
