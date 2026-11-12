#!/bin/bash
#
# conversation-observer.sh — Claude Code SessionStart hook that keeps the
# Conversation record current: it hands the payload to
# `workspaces conversation observe`, which writes where this conversation runs.
#
# Installed for every Claude session on the machine, so outside WorkSpaces
# (neither tile-scoped key set) it exits before starting anything. The app
# writes the bundled CLI's path in place of the placeholder when it extracts
# this file. Always exits 0: a failure here is never Claude's to report.

set -u

main() {
    if [[ -z "${WORKSPACES_CONVERSATIONS_DIR:-}" && -z "${WORKSPACES_HOST_SESSION_ID:-}" ]]; then
        exit 0
    fi
    local cli='@WORKSPACES_CLI@'
    if [[ -x "$cli" ]]; then
        "$cli" conversation observe >/dev/null 2>&1
    fi
    exit 0
}

main "$@"
