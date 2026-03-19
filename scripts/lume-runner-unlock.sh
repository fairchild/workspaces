#!/usr/bin/env bash
# Unlock the Lume runner VM's macOS login screen via VNC + AppleScript.
#
# The VM's lock screen cannot be unlocked over SSH because SSH sessions
# have no access to WindowServer. This script opens a VNC connection
# from the host and types the guest password through Screen Sharing.
#
# Usage:
#   ./scripts/lume-runner-unlock.sh          # open VNC + unlock
#   ./scripts/lume-runner-unlock.sh --vnc    # just open VNC, don't type password
#
# Prerequisites: VM must be running (`lume run ... --no-display &`)

set -euo pipefail

LUME_STORAGE="$HOME/Library/Application Support/WorkspaceManager/LumeStorage"
LUME_VM=workspaces-lume-runner
GUEST_PASSWORD=lumesetup26

# Get VNC URL from lume ls
VNC_URL=$(lume ls --storage "$LUME_STORAGE/workspace-vms" 2>/dev/null \
  | grep "$LUME_VM" \
  | grep -oE 'vnc://[^ ]+' || true)

if [ -z "$VNC_URL" ]; then
  echo "Error: Could not find VNC URL. Is the VM running?" >&2
  echo "  lume ls --storage \"$LUME_STORAGE/workspace-vms\"" >&2
  exit 1
fi

echo "Opening VNC: $VNC_URL"
open "$VNC_URL"

if [ "${1:-}" = "--vnc" ]; then
  echo "VNC opened. Skipping auto-unlock (--vnc flag)."
  exit 0
fi

echo "Waiting for Screen Sharing to connect..."
sleep 3

echo "Typing login password..."
osascript -e '
tell application "Screen Sharing" to activate
delay 1
tell application "System Events"
    tell process "Screen Sharing"
        click window 1
        delay 0.5
    end tell
    keystroke "'"$GUEST_PASSWORD"'"
    delay 0.3
    keystroke return
end tell
'

echo "Done. Check Screen Sharing window — should be at the desktop."
