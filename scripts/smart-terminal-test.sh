#!/bin/bash
# Smart terminal test - finds actual window position and tests keyboard input
# Works correctly on multi-monitor setups

set -e

SCREENSHOT_DIR="/tmp/smart-terminal-test"
mkdir -p "$SCREENSHOT_DIR"
rm -f "$SCREENSHOT_DIR"/*.png "$SCREENSHOT_DIR"/*.log

log() {
    echo "[$(date +%H:%M:%S)] $1"
}

cleanup() {
    log "Cleaning up..."
    pkill -f "WorkspaceManager" 2>/dev/null || true
}
trap cleanup EXIT

log "=== Smart Terminal Test ==="

# Kill existing
pkill -f "WorkspaceManager" 2>/dev/null || true
sleep 1

# Build
log "Building..."
cd "$(dirname "$0")/.." # repo root
swift build 2>&1 | grep -E "(error|Build complete)" || true

# Launch with log capture
log "Launching app..."
swift run 2>&1 &
APP_PID=$!
sleep 4

# Get actual window position and size
log "Getting window geometry..."
WINDOW_INFO=$(osascript -e '
tell application "System Events"
    tell process "WorkspaceManager"
        set w to window 1
        set pos to position of w
        set sz to size of w
        return (item 1 of pos as text) & "," & (item 2 of pos as text) & "," & (item 1 of sz as text) & "," & (item 2 of sz as text)
    end tell
end tell
' 2>/dev/null)

log "Window info: $WINDOW_INFO"

# Parse window geometry
WIN_X=$(echo "$WINDOW_INFO" | cut -d',' -f1)
WIN_Y=$(echo "$WINDOW_INFO" | cut -d',' -f2)
WIN_W=$(echo "$WINDOW_INFO" | cut -d',' -f3)
WIN_H=$(echo "$WINDOW_INFO" | cut -d',' -f4)

log "Window at ($WIN_X, $WIN_Y) size ${WIN_W}x${WIN_H}"

# Calculate terminal area (middle of window, accounting for sidebar ~250px and right pane ~300px)
# Terminal is roughly in the center-left area
SIDEBAR_WIDTH=250
TERMINAL_CENTER_X=$((WIN_X + SIDEBAR_WIDTH + 200))
TERMINAL_CENTER_Y=$((WIN_Y + WIN_H / 2))

log "Calculated terminal center: ($TERMINAL_CENTER_X, $TERMINAL_CENTER_Y)"

# Activate window
log "Activating window..."
osascript -e 'tell application "System Events" to set frontmost of process "WorkspaceManager" to true'
sleep 0.5

screencapture -x "$SCREENSHOT_DIR/01-initial.png"

# Click in terminal area
log "Clicking in terminal at ($TERMINAL_CENTER_X, $TERMINAL_CENTER_Y)..."
cliclick c:$TERMINAL_CENTER_X,$TERMINAL_CENTER_Y
sleep 0.5

screencapture -x "$SCREENSHOT_DIR/02-after-click.png"

# Check system log for our NSLog messages
log "Checking system log for terminal events..."
log_show --predicate 'process == "WorkspaceManager"' --last 10s 2>/dev/null | grep -E "\[Terminal|\[TerminalView" | tail -10 || echo "No logs found (try Console.app)"

# Type a test command
log "Typing 'echo SMART_TEST_WORKS'..."
cliclick t:"echo SMART_TEST_WORKS"
sleep 0.3

screencapture -x "$SCREENSHOT_DIR/03-after-type.png"

# Press Enter
log "Pressing Enter..."
osascript -e 'tell application "System Events" to key code 36'
sleep 1

screencapture -x "$SCREENSHOT_DIR/04-after-enter.png"

# Now test clicking in different areas to verify we're hitting the terminal
log ""
log "=== Testing different click positions ==="

# Try clicking a bit to the right (more into terminal area)
TERM_X2=$((TERMINAL_CENTER_X + 100))
log "Clicking further right at ($TERM_X2, $TERMINAL_CENTER_Y)..."
cliclick c:$TERM_X2,$TERMINAL_CENTER_Y
sleep 0.3
cliclick t:"echo POS2"
osascript -e 'tell application "System Events" to key code 36'
sleep 0.5

screencapture -x "$SCREENSHOT_DIR/05-pos2.png"

# Try clicking a bit lower
TERM_Y2=$((TERMINAL_CENTER_Y + 100))
log "Clicking lower at ($TERMINAL_CENTER_X, $TERM_Y2)..."
cliclick c:$TERMINAL_CENTER_X,$TERM_Y2
sleep 0.3
cliclick t:"echo POS3"
osascript -e 'tell application "System Events" to key code 36'
sleep 0.5

screencapture -x "$SCREENSHOT_DIR/06-pos3.png"

# Check logs again
log ""
log "=== Final log check ==="
log_show --predicate 'process == "WorkspaceManager"' --last 30s 2>/dev/null | grep -E "\[Terminal|\[TerminalView" | tail -20 || echo "No logs found"

log ""
log "=== Test Complete ==="
log "Screenshots saved to: $SCREENSHOT_DIR/"
ls -la "$SCREENSHOT_DIR"/*.png

log ""
log "Open screenshots with: open $SCREENSHOT_DIR/"
