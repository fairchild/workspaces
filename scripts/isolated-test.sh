#!/bin/bash
# Isolated terminal test - captures only the app window, ensures focus

set -e

SCREENSHOT_DIR="/tmp/isolated-terminal-test"
mkdir -p "$SCREENSHOT_DIR"
rm -f "$SCREENSHOT_DIR"/*

log() {
    echo "[$(date +%H:%M:%S)] $1"
}

# Capture only the WorkspaceManager window
capture_window() {
    local name="$1"
    # Get window ID and capture just that window
    local wid=$(osascript -e 'tell application "System Events" to tell process "WorkspaceManager" to get id of window 1' 2>/dev/null || echo "")
    if [ -n "$wid" ]; then
        screencapture -l "$wid" "$SCREENSHOT_DIR/$name.png" 2>/dev/null || screencapture -x "$SCREENSHOT_DIR/$name.png"
    else
        screencapture -x "$SCREENSHOT_DIR/$name.png"
    fi
    log "Captured: $name"
}

cleanup() {
    pkill -f "WorkspaceManager" 2>/dev/null || true
}
trap cleanup EXIT

log "=== Isolated Terminal Test ==="

# Kill existing and close Photos
pkill -f "WorkspaceManager" 2>/dev/null || true
osascript -e 'tell application "Photos" to quit' 2>/dev/null || true
sleep 1

log "Building..."
cd "$(dirname "$0")/.." # repo root
swift build 2>&1 | grep -E "(error|Build complete)" || true

log "Launching..."
swift run WorkspaceManager > "$SCREENSHOT_DIR/app.log" 2>&1 &
APP_PID=$!
sleep 4

# Position and activate aggressively
log "Positioning and activating window..."
osascript << 'EOF'
tell application "System Events"
    tell process "WorkspaceManager"
        set frontmost to true
        set position of window 1 to {100, 100}
        set size of window 1 to {1200, 800}
    end tell
end tell
delay 0.5
tell application "System Events"
    tell process "WorkspaceManager"
        set frontmost to true
    end tell
end tell
EOF
sleep 1

capture_window "01-initial"

# Get window position
WIN_INFO=$(osascript -e 'tell application "System Events" to tell process "WorkspaceManager" to get {position, size} of window 1')
log "Window info: $WIN_INFO"

# Parse - format is {{x,y},{w,h}}
WIN_X=$(echo "$WIN_INFO" | sed 's/[^0-9,]//g' | cut -d',' -f1)
WIN_Y=$(echo "$WIN_INFO" | sed 's/[^0-9,]//g' | cut -d',' -f2)
WIN_W=$(echo "$WIN_INFO" | sed 's/[^0-9,]//g' | cut -d',' -f3)
WIN_H=$(echo "$WIN_INFO" | sed 's/[^0-9,]//g' | cut -d',' -f4)
log "Parsed: x=$WIN_X y=$WIN_Y w=$WIN_W h=$WIN_H"

# Click on workspace in sidebar (lower part of sidebar)
# Sidebar is ~200px wide, workspace items around y=200-300 from window top
SIDEBAR_X=$((WIN_X + 120))
WORKSPACE_Y=$((WIN_Y + 200))

log "Clicking workspace at ($SIDEBAR_X, $WORKSPACE_Y)..."
osascript -e "tell application \"System Events\" to tell process \"WorkspaceManager\" to set frontmost to true"
cliclick c:$SIDEBAR_X,$WORKSPACE_Y
sleep 2

capture_window "02-workspace-selected"

# Click in terminal area (center of window, past sidebar)
TERM_X=$((WIN_X + 500))
TERM_Y=$((WIN_Y + 400))

log "Clicking terminal at ($TERM_X, $TERM_Y)..."
osascript -e "tell application \"System Events\" to tell process \"WorkspaceManager\" to set frontmost to true"
sleep 0.3
cliclick c:$TERM_X,$TERM_Y
sleep 1

capture_window "03-terminal-clicked"

# Type test command
log "Typing 'echo KEYBOARD_WORKS'..."
osascript -e "tell application \"System Events\" to tell process \"WorkspaceManager\" to set frontmost to true"
sleep 0.2
cliclick t:"echo KEYBOARD_WORKS"
sleep 0.5

capture_window "04-after-typing"

# Press Enter
log "Pressing Enter..."
osascript -e 'tell application "System Events" to key code 36'
sleep 1

capture_window "05-after-enter"

# Type another command
log "Typing 'ls -la'..."
cliclick t:"ls -la"
sleep 0.3
osascript -e 'tell application "System Events" to key code 36'
sleep 2

capture_window "06-after-ls"

log ""
log "=== App Logs ==="
cat "$SCREENSHOT_DIR/app.log" | grep -E "\[Terminal" | tail -20

log ""
log "=== Results ==="
ls -la "$SCREENSHOT_DIR"/*.png
log ""
log "View: open $SCREENSHOT_DIR/"
