#!/bin/bash
# Simple manual verification test
# Run this, then manually select a workspace in the app

echo "=== Keyboard Verification Test ==="
echo ""
echo "Instructions:"
echo "1. This script will launch WorkspaceManager"
echo "2. YOU manually click on a workspace in the sidebar"
echo "3. YOU click in the terminal area"
echo "4. Try typing a command like 'ls' or 'echo hello'"
echo ""
echo "Press Enter to launch the app..."
read

pkill -f "WorkspaceManager" 2>/dev/null || true
sleep 1

cd "20 20 12 61 79 80 81 701 33 98 100 204 250 395 398 399 400dirname "-e")/../.." # repo root
echo "Building..."
swift build 2>&1 | grep -E "(error|Build complete)" || true

echo ""
echo "Launching WorkspaceManager..."
swift run WorkspaceManager 2>&1 | grep -E "\[Terminal" &

echo ""
echo "App launched. Please:"
echo "1. Select a workspace in the sidebar"
echo "2. Click in the terminal"
echo "3. Type commands"
echo ""
echo "Press Ctrl+C when done testing."
wait
