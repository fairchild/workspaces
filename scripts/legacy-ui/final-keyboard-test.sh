#!/bin/bash
# Final keyboard test - clicks directly on workspace item

set -e

SCREENSHOT_DIR="/tmp/final-keyboard-test"
mkdir -p "$SCREENSHOT_DIR"
rm -f "$SCREENSHOT_DIR"/*

log() { echo "[$(date +%H:%M:%S)] $1"; }

cleanup() { pkill -f "WorkspaceManager" 2>/dev/null || true; }
trap cleanup EXIT

log "=== Final Keyboard Test ==="

pkill -f "WorkspaceManager" 2>/dev/null || true
sleep 1

cd "20 20 12 61 79 80 81 701 33 98 100 204 250 395 398 399 400dirname "-e")/../.." # repo root
swift build 2>&1 | grep -E "(error|Build complete)" || true

log "Launching..."
swift run WorkspaceManager > "$SCREENSHOT_DIR/app.log" 2>&1 &
sleep 4

# Position window
osascript << 'EOF'
tell application "System Events"
    tell process "WorkspaceManager"
        set frontmost to true
        set position of window 1 to {100, 100}
        set size of window 1 to {1200, 800}
    end tell
end tell
EOF
sleep 1

screencapture -x "$SCREENSHOT_DIR/01-initial.png"

# Use AppleScript to click on the workspace item in the list
log "Selecting workspace via UI scripting..."
osascript << 'EOF'
tell application "System Events"
    tell process "WorkspaceManager"
        set frontmost to true
        delay 0.5
        -- Click on the outline (list) in the sidebar
        -- The workspace should be in the second section
        try
            -- Try clicking on "code-council-v1" text
            click static text "code-council-v1" of window 1
        on error
            -- Fallback: click lower in the sidebar area
            click at {220, 350}
        end try
    end tell
end tell
EOF
sleep 2

screencapture -x "$SCREENSHOT_DIR/02-after-workspace-click.png"

# Now click in the terminal area
log "Clicking in terminal area..."
osascript << 'EOF'
tell application "System Events"
    tell process "WorkspaceManager"
        set frontmost to true
        delay 0.3
        click at {600, 500}
    end tell
end tell
EOF
sleep 1

screencapture -x "$SCREENSHOT_DIR/03-terminal-clicked.png"

# Type using System Events keystroke (more reliable than cliclick)
log "Typing 'echo TEST_SUCCESS'..."
osascript << 'EOF'
tell application "System Events"
    tell process "WorkspaceManager"
        set frontmost to true
        delay 0.2
        keystroke "echo TEST_SUCCESS"
        delay 0.3
        key code 36 -- Enter
    end tell
end tell
EOF
sleep 2

screencapture -x "$SCREENSHOT_DIR/04-after-echo.png"

# Type another command
log "Typing 'pwd'..."
osascript << 'EOF'
tell application "System Events"
    tell process "WorkspaceManager"
        set frontmost to true
        delay 0.2
        keystroke "pwd"
        delay 0.2
        key code 36
    end tell
end tell
EOF
sleep 1

screencapture -x "$SCREENSHOT_DIR/05-after-pwd.png"

log ""
log "=== App Logs ==="
cat "$SCREENSHOT_DIR/app.log" | grep -E "\[Terminal" | tail -15

log ""
log "=== Screenshots ==="
ls -la "$SCREENSHOT_DIR"/*.png
log ""
log "View results: open $SCREENSHOT_DIR/"
