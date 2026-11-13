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
# descriptor to the server, so a stopped server would hold a pipe open. One
# owner cleans up the lookup's file, client and deadline, on return or on any
# signal. The deadline kills only a process that is still this shell's child,
# and it is stopped before this shell starts any other child. The app writes
# the bundled CLI's path in place of the placeholder when it extracts this
# file. Always exits 0: a failure here is never Claude's to report.

set -u

readonly KEY=WORKSPACES_CONVERSATIONS_DIR
lookup_out=""
lookup_client=""
lookup_guard=""

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
    trap end_lookup EXIT
    trap 'exit 0' TERM INT HUP
    local answer=""
    if ask_session "$socket" "$session"; then
        answer="$(<"$lookup_out")"
    fi
    end_lookup
    trap - EXIT TERM INT HUP
    [[ -n "$answer" && "${answer%%$'\n'*}" == "$pid" ]] || return 1
    local line="${answer#*$'\n'}"
    [[ "$line" == "$KEY="?* ]] || return 1
    export WORKSPACES_CONVERSATIONS_DIR="${line#"$KEY="}"
}

ask_session() {
    local socket=$1 session=$2
    lookup_out="$(mktemp "${TMPDIR:-/tmp}/workspaces-observer.XXXXXX")" || return 1
    PATH="$PATH:/opt/homebrew/bin:/usr/local/bin" tmux -S "$socket" \
        display-message -p -t "$session" '#{pid}' \; show-environment -t "$session" "$KEY" \
        </dev/null >"$lookup_out" 2>/dev/null &
    lookup_client=$!
    end_at_deadline "$lookup_client" </dev/null >/dev/null 2>&1 &
    lookup_guard=$!
    wait "$lookup_client"
    local status=$?
    lookup_client=""
    stop_guard
    return "$status"
}

end_lookup() {
    stop_guard
    if [[ -n "$lookup_client" ]]; then
        kill_child "$lookup_client"
        wait "$lookup_client" 2>/dev/null
        lookup_client=""
    fi
    if [[ -n "$lookup_out" ]]; then
        rm -f "$lookup_out"
        lookup_out=""
    fi
}

stop_guard() {
    if [[ -n "$lookup_guard" ]]; then
        kill -TERM "$lookup_guard" 2>/dev/null
        wait "$lookup_guard" 2>/dev/null
        lookup_guard=""
    fi
}

end_at_deadline() {
    local client=$1 nap
    trap 'kill "$nap" 2>/dev/null; exit 0' TERM
    sleep 1 &
    nap=$!
    wait "$nap"
    kill_child "$client"
}

kill_child() {
    local parent
    parent="$(ps -o ppid= -p "$1" 2>/dev/null)" || return 0
    if ((parent == $$)); then
        kill -KILL "$1" 2>/dev/null
    fi
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
