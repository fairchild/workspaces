#!/bin/bash
# Debug test focusing on first responder and keyboard events

set -e

SCREENSHOT_DIR="/tmp/focus-debug-test"
mkdir -p "$SCREENSHOT_DIR"
rm -f "$SCREENSHOT_DIR"/*

log() {
    echo "[$(date +%H:%M:%S)] $1"
}

cleanup() {
    log "Cleaning up..."
    pkill -f "WorkspaceManager" 2>/dev/null || true
}
trap cleanup EXIT

log "=== Focus Debug Test ==="

# Kill existing
pkill -f "WorkspaceManager" 2>/dev/null || true
sleep 1

# Build
log "Building..."
cd "$(dirname "$0")/.." # repo root
swift build 2>&1 | grep -E "(error|Build complete)" || true

# Launch and capture stderr/stdout separately
log "Launching app (capturing logs to file)..."
swift run WorkspaceManager > "$SCREENSHOT_DIR/stdout.log" 2>&1 &
APP_PID=$!
sleep 4

# Move window to primary display first
log "Moving window to primary display..."
osascript << 'EOF'
tell application "System Events"
    tell process "WorkspaceManager"
        set position of window 1 to {100, 100}
    end tell
end tell
EOF
sleep 1

# Get new position
log "Getting window position after move..."
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

log "Window now at: $WINDOW_INFO"

WIN_X=$(echo "$WINDOW_INFO" | cut -d',' -f1)
WIN_Y=$(echo "$WINDOW_INFO" | cut -d',' -f2)
WIN_W=$(echo "$WINDOW_INFO" | cut -d',' -f3)
WIN_H=$(echo "$WINDOW_INFO" | cut -d',' -f4)

# Calculate terminal click point (past sidebar)
CLICK_X=$((WIN_X + 400))
CLICK_Y=$((WIN_Y + WIN_H / 2))

log "Will click at: ($CLICK_X, $CLICK_Y)"

screencapture -x "$SCREENSHOT_DIR/01-before-click.png"

# Click to focus terminal
log "Clicking to focus terminal..."
cliclick c:$CLICK_X,$CLICK_Y
sleep 0.5

screencapture -x "$SCREENSHOT_DIR/02-after-click.png"

# Check first responder
log "Checking first responder..."
osascript << 'EOF'
tell application "System Events"
    tell process "WorkspaceManager"
        set fr to focused of window 1
        log "Window focused: " & fr
        -- Try to get more info
        set uiElems to every UI element of window 1
        repeat with elem in uiElems
            try
                if focused of elem then
                    log "Focused element: " & (description of elem)
                end if
            end try
        end repeat
    end tell
end tell
EOF

# Now try typing with direct keystroke to the app
log "Typing 'ls' using keystroke to app..."
osascript << 'EOF'
tell application "System Events"
    tell process "WorkspaceManager"
        keystroke "ls"
    end tell
end tell
EOF
sleep 0.5

screencapture -x "$SCREENSHOT_DIR/03-after-keystroke.png"

log "Pressing return..."
osascript << 'EOF'
tell application "System Events"
    tell process "WorkspaceManager"
        key code 36
    end tell
end tell
EOF
sleep 1

screencapture -x "$SCREENSHOT_DIR/04-after-return.png"

# Also try with cliclick
log "Clicking again and trying cliclick typing..."
cliclick c:$CLICK_X,$CLICK_Y
sleep 0.3
cliclick t:"echo CLICLICK_TEST"
sleep 0.3
osascript -e 'tell application "System Events" to key code 36'
sleep 1

screencapture -x "$SCREENSHOT_DIR/05-after-cliclick.png"

log ""
log "=== App stdout/stderr ==="
cat "$SCREENSHOT_DIR/stdout.log" | tail -50

log ""
log "=== Test Complete ==="
ls -la "$SCREENSHOT_DIR"
