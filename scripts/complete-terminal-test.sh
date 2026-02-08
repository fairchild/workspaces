#!/bin/bash
# Complete terminal test - selects workspace first, then tests keyboard

set -e

SCREENSHOT_DIR="/tmp/complete-terminal-test"
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

log "=== Complete Terminal Test ==="

# Kill existing
pkill -f "WorkspaceManager" 2>/dev/null || true
sleep 1

# Build
log "Building..."
cd /Users/fairchild/code/services/workspaces/WorkspaceManager
swift build 2>&1 | grep -E "(error|Build complete)" || true

# Launch
log "Launching app..."
swift run > "$SCREENSHOT_DIR/app.log" 2>&1 &
APP_PID=$!
sleep 4

# Move window to primary display
log "Moving window to primary display..."
osascript << 'EOF'
tell application "System Events"
    tell process "WorkspaceManager"
        set position of window 1 to {50, 50}
        set frontmost to true
    end tell
end tell
EOF
sleep 0.5

# Get window position
WINDOW_INFO=$(osascript -e '
tell application "System Events"
    tell process "WorkspaceManager"
        set w to window 1
        set pos to position of w
        set sz to size of w
        return (item 1 of pos as text) & "," & (item 2 of pos as text) & "," & (item 1 of sz as text) & "," & (item 2 of sz as text)
    end tell
end tell
')

log "Window at: $WINDOW_INFO"

WIN_X=$(echo "$WINDOW_INFO" | cut -d',' -f1)
WIN_Y=$(echo "$WINDOW_INFO" | cut -d',' -f2)
WIN_W=$(echo "$WINDOW_INFO" | cut -d',' -f3)
WIN_H=$(echo "$WINDOW_INFO" | cut -d',' -f4)

screencapture -x "$SCREENSHOT_DIR/01-initial.png"

# Step 1: Click on a workspace in the sidebar to select it
# Workspace items are typically in the lower part of the sidebar (after repos section)
# Sidebar is roughly 200px wide, workspace items start around y=150

SIDEBAR_X=$((WIN_X + 100))  # Middle of sidebar
WORKSPACE_Y=$((WIN_Y + 150))  # Approximate location of first workspace

log "Step 1: Clicking on workspace in sidebar at ($SIDEBAR_X, $WORKSPACE_Y)..."
cliclick c:$SIDEBAR_X,$WORKSPACE_Y
sleep 1

screencapture -x "$SCREENSHOT_DIR/02-after-sidebar-click.png"

# Check if we need to click lower (if we hit the repo, not the workspace)
# Try a bit lower
WORKSPACE_Y2=$((WIN_Y + 200))
log "Trying lower position ($SIDEBAR_X, $WORKSPACE_Y2)..."
cliclick c:$SIDEBAR_X,$WORKSPACE_Y2
sleep 1

screencapture -x "$SCREENSHOT_DIR/03-after-lower-click.png"

# Also try double-click in case that's needed
log "Double-clicking on workspace..."
cliclick dc:$SIDEBAR_X,$WORKSPACE_Y2
sleep 2

screencapture -x "$SCREENSHOT_DIR/04-after-double-click.png"

# Step 2: Now click in the terminal area (center-right of window)
TERMINAL_X=$((WIN_X + 500))
TERMINAL_Y=$((WIN_Y + WIN_H / 2))

log "Step 2: Clicking in terminal area at ($TERMINAL_X, $TERMINAL_Y)..."
cliclick c:$TERMINAL_X,$TERMINAL_Y
sleep 0.5

screencapture -x "$SCREENSHOT_DIR/05-clicked-terminal.png"

# Step 3: Test keyboard input
log "Step 3: Testing keyboard input..."
log "Typing 'echo HELLO_TERMINAL'..."
cliclick t:"echo HELLO_TERMINAL"
sleep 0.3

screencapture -x "$SCREENSHOT_DIR/06-after-typing.png"

log "Pressing Enter..."
osascript -e 'tell application "System Events" to key code 36'
sleep 1

screencapture -x "$SCREENSHOT_DIR/07-after-enter.png"

# Step 4: Test another command
log "Step 4: Testing pwd command..."
cliclick t:"pwd"
sleep 0.2
osascript -e 'tell application "System Events" to key code 36'
sleep 1

screencapture -x "$SCREENSHOT_DIR/08-after-pwd.png"

# Check app logs
log ""
log "=== App Logs ==="
cat "$SCREENSHOT_DIR/app.log" 2>/dev/null | head -50 || echo "No logs"

log ""
log "=== Test Complete ==="
log "Screenshots saved to: $SCREENSHOT_DIR/"
ls -la "$SCREENSHOT_DIR"/*.png

log ""
log "View results with: open $SCREENSHOT_DIR/"
