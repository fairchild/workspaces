#!/bin/bash
#
# conversation-observer.sh — Claude Code SessionStart hook that keeps the
# Conversation record current: it hands the payload to
# `workspaces conversation observe`, which writes where this conversation runs.
#
# Installed for every Claude session on the machine, so outside WorkSpaces
# (neither tile-scoped key set, and no tmux session naming a records directory)
# it exits before starting anything. A shell older than its tmux session's
# environment lacks the key; the session still has it, if the server answering
# on `$TMUX`'s socket is the one `$TMUX` names and it answers within a second.
# The answer goes through a file, not a pipe: a tmux client hands its output
# descriptor to the server, so a stopped server would hold a pipe open.
# The app writes the bundled CLI's path in place of the placeholder when it
# extracts this file. Always exits 0: a failure here is never Claude's to report.

set -u

readonly KEY=WORKSPACES_CONVERSATIONS_DIR

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
    local server="${TMUX%,*}"
    local pid="${server##*,}"
    local socket="${server%,*}"
    local session="\$${TMUX##*,}"
    local out answer=""
    out="$(mktemp "${TMPDIR:-/tmp}/workspaces-observer.XXXXXX")" || return 1
    if ask_session "$socket" "$session" "$out"; then
        answer="$(<"$out")"
    fi
    rm -f "$out"
    [[ -n "$answer" && "${answer%%$'\n'*}" == "$pid" ]] || return 1
    local line="${answer#*$'\n'}"
    [[ "$line" == "$KEY="?* ]] || return 1
    export WORKSPACES_CONVERSATIONS_DIR="${line#"$KEY="}"
}

ask_session() {
    local socket=$1 session=$2 out=$3
    PATH="$PATH:/opt/homebrew/bin:/usr/local/bin" tmux -S "$socket" \
        display-message -p -t "$session" '#{pid}' \; show-environment -t "$session" "$KEY" \
        </dev/null >"$out" 2>/dev/null &
    local client=$!
    end_at_deadline "$client" </dev/null >/dev/null 2>&1 &
    local guard=$!
    wait "$client"
    local status=$?
    kill -TERM "$guard" 2>/dev/null
    wait "$guard" 2>/dev/null
    return "$status"
}

end_at_deadline() {
    local client=$1 nap
    trap 'kill "$nap" 2>/dev/null; exit 0' TERM
    sleep 1 &
    nap=$!
    wait "$nap"
    kill -KILL "$client" 2>/dev/null
}

main "$@"
