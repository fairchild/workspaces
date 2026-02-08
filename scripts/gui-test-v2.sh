#!/bin/bash
# Enhanced GUI test with screenshot capture

set -e

SCREENSHOT_DIR="/tmp/workspace-manager-test"
mkdir -p "$SCREENSHOT_DIR"

echo "=== WorkspaceManager GUI Test v2 ==="

# Kill any existing instance
pkill -f "WorkspaceManager" 2>/dev/null || true
sleep 1

# Build first
echo "1. Building..."
swift build 2>&1 | grep -E "(error|Build complete)" || true

# Launch app in background
echo "2. Launching app..."
swift run 2>&1 > "$SCREENSHOT_DIR/app-output.log" &
APP_PID=$!
sleep 5

# Take initial screenshot
echo "3. Taking initial screenshot..."
screencapture -x "$SCREENSHOT_DIR/01-initial.png"

# Activate the app window
echo "4. Activating WorkspaceManager window..."
osascript -e 'tell application "System Events" to set frontmost of process "WorkspaceManager" to true' 2>/dev/null || echo "Could not activate"
sleep 1

# Take screenshot after activation
screencapture -x "$SCREENSHOT_DIR/02-activated.png"

# Click in terminal area
echo "5. Clicking in terminal area..."
cliclick c:800,500 2>&1 || echo "Click failed"
sleep 0.5

screencapture -x "$SCREENSHOT_DIR/03-after-click.png"

# Type test text
echo "6. Typing 'echo KEYBOARD_TEST_SUCCESS'..."
cliclick t:"echo KEYBOARD_TEST_SUCCESS" 2>&1 || echo "Type failed"
sleep 0.5

screencapture -x "$SCREENSHOT_DIR/04-after-type.png"

# Press Enter
echo "7. Pressing Enter..."
osascript -e 'tell application "System Events" to key code 36' 2>&1 || echo "Enter failed"
sleep 2

screencapture -x "$SCREENSHOT_DIR/05-after-enter.png"

echo ""
echo "8. Killing app..."
kill $APP_PID 2>/dev/null || true
wait $APP_PID 2>/dev/null || true

echo ""
echo "=== Test Complete ==="
echo "Screenshots saved to: $SCREENSHOT_DIR/"
ls -la "$SCREENSHOT_DIR/"
echo ""
echo "App output log:"
cat "$SCREENSHOT_DIR/app-output.log" | head -30

