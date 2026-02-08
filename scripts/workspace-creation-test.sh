#!/bin/bash
# Test workspace creation flow - reproduces "characters streaming" issue

set -e

SCREENSHOT_DIR="/tmp/workspace-creation-test"
mkdir -p "$SCREENSHOT_DIR"
rm -f "$SCREENSHOT_DIR"/*.png "$SCREENSHOT_DIR"/*.log

log() {
    echo "[$(date +%H:%M:%S)] $1"
}

screenshot() {
    local name="$1"
    screencapture -x "$SCREENSHOT_DIR/$name.png"
    log "Screenshot: $name"
}

cleanup() {
    log "Cleaning up..."
    pkill -f "WorkspaceManager" 2>/dev/null || true
}
trap cleanup EXIT

log "=== Workspace Creation Test ==="
log "This test will capture app output to diagnose character streaming"

# Kill any existing instance
pkill -f "WorkspaceManager" 2>/dev/null || true
sleep 1

# Build
log "Building..."
cd /Users/fairchild/code/services/workspaces/WorkspaceManager
swift build 2>&1 | grep -E "(error|Build complete)" || true

# Launch app WITH output capture
log "Launching app (capturing stdout/stderr)..."
swift run 2>&1 | tee "$SCREENSHOT_DIR/app-output.log" &
APP_PID=$!
sleep 4

# Activate
osascript -e 'tell application "System Events" to set frontmost of process "WorkspaceManager" to true'
sleep 1

screenshot "01-initial"

# Look for "+ Add Repo" button - usually in sidebar header area
# First, let's see the window layout
log "Window info:"
osascript -e 'tell application "System Events"
    tell process "WorkspaceManager"
        set wins to every window
        repeat with w in wins
            log "  Window: " & (name of w as text) & " at " & (position of w as text) & " size " & (size of w as text)
        end repeat
    end tell
end tell' 2>&1

# Click on sidebar area to add a repo (usually top-left area)
log "Looking for Add Repo button..."
screenshot "02-before-add-repo"

# Try clicking where "+" button typically is (top of sidebar)
log "Clicking Add Repo area (150, 80)..."
cliclick c:150,80
sleep 1
screenshot "03-after-add-repo-click"

# If a file picker appeared, we need to select a repo
# Let's try keyboard shortcut instead - Cmd+O might work
log "Trying Cmd+N for new workspace..."
osascript -e 'tell application "System Events" to keystroke "n" using command down'
sleep 1
screenshot "04-after-cmd-n"

# If there's a dialog, try to interact with it
log "Checking for dialogs..."
sleep 1
screenshot "05-dialog-check"

# Now let's test clicking in different areas of the sidebar
log "Clicking various sidebar positions to find workspace creation..."

# Click lower in sidebar where workspace list might be
cliclick c:150,200
sleep 0.5
screenshot "06-sidebar-200"

cliclick c:150,300
sleep 0.5
screenshot "07-sidebar-300"

# If a workspace/repo is selected, there might be a "New Workspace" option
# Try right-clicking for context menu
log "Right-clicking for context menu..."
cliclick rc:150,200
sleep 1
screenshot "08-context-menu"

# Press Escape to dismiss any menu
osascript -e 'tell application "System Events" to key code 53'
sleep 0.5

# Let's check the app output for terminal creation logs
log ""
log "=== App Output (terminal logs) ==="
cat "$SCREENSHOT_DIR/app-output.log" | grep -E "\[Terminal|\[TerminalView" | tail -20 || echo "No terminal logs found"

log ""
log "=== Full App Output ==="
cat "$SCREENSHOT_DIR/app-output.log" | tail -50

log ""
log "=== Test Complete ==="
log "Screenshots: $SCREENSHOT_DIR/"
ls -la "$SCREENSHOT_DIR"/*.png
