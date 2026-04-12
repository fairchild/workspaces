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
GUEST_PASSWORD="${LUME_GUEST_PASSWORD:-${LUME_STANDALONE_SSH_PASSWORD:-}}"

if [ -z "$GUEST_PASSWORD" ]; then
  echo "Set LUME_GUEST_PASSWORD (or LUME_STANDALONE_SSH_PASSWORD) before unlocking the runner VM." >&2
  exit 1
fi

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

echo "Enabling control mode and typing login password..."
osascript <<APPLESCRIPT
tell application "Screen Sharing" to activate
delay 1

tell application "System Events"
    tell process "Screen Sharing"
        -- Enable control mode via the toolbar's "Control" toggle.
        -- Screen Sharing starts in observe-only mode; keystrokes are
        -- silently dropped unless control is enabled first.
        try
            -- Try clicking the Control toolbar button (mouse cursor icon)
            click checkbox 1 of toolbar 1 of window 1
            delay 0.5
        on error
            -- If the toolbar item isn't a checkbox, try the menu instead
            try
                click menu item "Use Shared Control" of menu "Connection" of menu bar 1
                delay 0.5
            end try
        end try

        -- Click inside the window to focus the VM's password field
        click window 1
        delay 0.5
    end tell

    -- Type the password and submit
    keystroke "$GUEST_PASSWORD"
    delay 0.3
    keystroke return
end tell
APPLESCRIPT

echo "Done. Check Screen Sharing window — should be at the desktop."
