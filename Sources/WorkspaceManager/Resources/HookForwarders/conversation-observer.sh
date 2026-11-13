#!/bin/bash
#
# conversation-observer.sh — Claude Code SessionStart hook that keeps the
# Conversation record current: it hands the payload to
# `workspaces conversation observe`, which writes where this conversation runs.
#
# Installed for every Claude session on the machine, so outside WorkSpaces
# (neither tile-scoped key set, and no tmux session naming a records directory)
# it exits before starting anything. A shell older than its tmux session's
# environment lacks the key; the session still has it. The app writes the
# bundled CLI's path in place of the placeholder when it extracts this file.
# Always exits 0: a failure here is never Claude's to report.

set -u

main() {
    if [[ -z "${WORKSPACES_CONVERSATIONS_DIR:-}" ]]; then
        adopt_session_directory || [[ -n "${WORKSPACES_HOST_SESSION_ID:-}" ]] || exit 0
    fi
    local cli='@WORKSPACES_CLI@'
    if [[ -x "$cli" ]]; then
        "$cli" conversation observe >/dev/null 2>&1
    fi
    exit 0
}

adopt_session_directory() {
    [[ -n "${TMUX:-}" ]] || return 1
    local key=WORKSPACES_CONVERSATIONS_DIR
    local socket="${TMUX%,*,*}"
    local session="\$${TMUX##*,}"
    local line
    line="$(PATH="$PATH:/opt/homebrew/bin:/usr/local/bin" tmux -S "$socket" show-environment -t "$session" "$key" 2>/dev/null)" || return 1
    [[ "$line" == "$key="?* ]] || return 1
    export WORKSPACES_CONVERSATIONS_DIR="${line#"$key="}"
}

main "$@"
