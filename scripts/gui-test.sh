#!/bin/bash
# GUI test script for WorkspaceManager terminal keyboard input

set -e

echo "=== WorkspaceManager GUI Test ==="

# Kill any existing instance
pkill -f "WorkspaceManager" 2>/dev/null || true
sleep 1

# Build first
echo "1. Building..."
cd "$(dirname "$0")/.." # repo root
swift build 2>&1 | grep -E "(error|Build complete)" || true

# Launch app in background, capture output
echo "2. Launching app (output will show below)..."
swift run 2>&1 &
APP_PID=$!
sleep 4

# Activate the app window
echo "3. Activating WorkspaceManager window..."
osascript -e 'tell application "System Events" to set frontmost of process "WorkspaceManager" to true' 2>/dev/null || echo "Could not activate (may need accessibility permissions)"
sleep 1

echo "4. Clicking in terminal area (800,500)..."
cliclick c:800,500 2>&1 || echo "Click failed"
sleep 0.5

echo "5. Typing test text..."
cliclick t:"ls" 2>&1 || echo "Type failed"
sleep 0.5

echo "6. Pressing Enter..."
osascript -e 'tell application "System Events" to key code 36' 2>&1 || echo "Enter failed"
sleep 2

echo ""
echo "7. Killing app..."
kill $APP_PID 2>/dev/null || true
wait $APP_PID 2>/dev/null || true

echo ""
echo "=== Test Complete ==="
echo "If you see terminal output above showing 'ls' results, keyboard input works!"
echo "If not, the keyboard fix didn't work."
