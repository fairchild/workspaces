#!/bin/bash
# Comprehensive terminal test suite for WorkspaceManager
# Tests keyboard input, focus behavior, and workspace creation

set -e

SCREENSHOT_DIR="/tmp/workspace-manager-test"
LOG_FILE="$SCREENSHOT_DIR/test.log"
mkdir -p "$SCREENSHOT_DIR"
rm -f "$SCREENSHOT_DIR"/*.png "$LOG_FILE"

log() {
    echo "[$(date +%H:%M:%S)] $1" | tee -a "$LOG_FILE"
}

screenshot() {
    local name="$1"
    screencapture -x "$SCREENSHOT_DIR/$name.png"
    log "Screenshot: $name.png"
}

# Cleanup function
cleanup() {
    log "Cleaning up..."
    pkill -f "WorkspaceManager" 2>/dev/null || true
}
trap cleanup EXIT

log "=== WorkspaceManager Terminal Test Suite ==="
log "Screenshots will be saved to: $SCREENSHOT_DIR"

# Kill any existing instance
pkill -f "WorkspaceManager" 2>/dev/null || true
sleep 1

# Build
log "Building app..."
cd "$(dirname "$0")/.." # repo root
if ! swift build 2>&1 | tee -a "$LOG_FILE" | grep -q "Build complete"; then
    log "ERROR: Build failed"
    exit 1
fi
log "Build successful"

# Launch app
log "Launching app..."
swift run 2>&1 >> "$LOG_FILE" &
APP_PID=$!
sleep 4

screenshot "01-app-launched"

# Get window info
log "Getting window information..."
osascript -e 'tell application "System Events"
    set procs to every process whose name contains "WorkspaceManager"
    repeat with p in procs
        set winList to every window of p
        repeat with w in winList
            log "Window: " & (name of w) & " position: " & (position of w) & " size: " & (size of w)
        end repeat
    end repeat
end tell' 2>&1 | tee -a "$LOG_FILE"

# Activate window
log "Activating app window..."
osascript -e 'tell application "System Events" to set frontmost of process "WorkspaceManager" to true'
sleep 1

screenshot "02-window-activated"

# === TEST 1: Check if terminal area exists ===
log ""
log "=== TEST 1: Terminal Area Detection ==="

# Click in the center-right area where terminal should be
# Window is ~1400x900, terminal is middle pane
log "Clicking in terminal area (700, 450)..."
cliclick c:700,450
sleep 0.5

screenshot "03-clicked-terminal-area"

# === TEST 2: Basic keyboard input ===
log ""
log "=== TEST 2: Basic Keyboard Input ==="

log "Waiting for terminal to settle..."
sleep 1

log "Typing 'pwd'..."
cliclick t:"pwd"
sleep 0.3

screenshot "04-typed-pwd"

log "Pressing Enter..."
osascript -e 'tell application "System Events" to key code 36'
sleep 1

screenshot "05-after-pwd-enter"

# === TEST 3: Multiple keystrokes ===
log ""
log "=== TEST 3: Multiple Keystrokes ==="

log "Typing 'echo TEST123'..."
cliclick t:"echo TEST123"
sleep 0.3
osascript -e 'tell application "System Events" to key code 36'
sleep 1

screenshot "06-after-echo"

# === TEST 4: Special keys ===
log ""
log "=== TEST 4: Special Keys (Ctrl+C) ==="

log "Starting a sleep command..."
cliclick t:"sleep 10"
sleep 0.2
osascript -e 'tell application "System Events" to key code 36'
sleep 1

screenshot "07-sleep-started"

log "Sending Ctrl+C..."
osascript -e 'tell application "System Events" to keystroke "c" using control down'
sleep 1

screenshot "08-after-ctrl-c"

# === TEST 5: Click away and back ===
log ""
log "=== TEST 5: Focus Recovery After Click Away ==="

log "Clicking in sidebar area..."
cliclick c:150,300
sleep 0.5

screenshot "09-clicked-sidebar"

log "Clicking back in terminal..."
cliclick c:700,450
sleep 0.5

log "Typing after refocus..."
cliclick t:"echo REFOCUS_TEST"
sleep 0.2
osascript -e 'tell application "System Events" to key code 36'
sleep 1

screenshot "10-after-refocus-test"

# === TEST 6: Arrow keys ===
log ""
log "=== TEST 6: Arrow Keys (Command History) ==="

log "Pressing Up arrow for command history..."
osascript -e 'tell application "System Events" to key code 126'  # Up arrow
sleep 0.5

screenshot "11-after-up-arrow"

# === Summary ===
log ""
log "=== TEST COMPLETE ==="
log "Screenshots saved to: $SCREENSHOT_DIR/"
log ""
log "Files:"
ls -la "$SCREENSHOT_DIR"/*.png 2>/dev/null | while read line; do
    log "  $line"
done

log ""
log "Review screenshots to verify:"
log "  - 04-typed-pwd.png: Should show 'pwd' typed at prompt"
log "  - 05-after-pwd-enter.png: Should show pwd output"
log "  - 06-after-echo.png: Should show 'TEST123'"
log "  - 08-after-ctrl-c.png: Should show interrupted sleep"
log "  - 10-after-refocus-test.png: Should show 'REFOCUS_TEST'"
log "  - 11-after-up-arrow.png: Should show previous command"

log ""
log "Open screenshots with: open $SCREENSHOT_DIR/"
