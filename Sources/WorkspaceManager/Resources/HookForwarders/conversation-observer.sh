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
# signal; a signal while they are being started waits until all three are
# recorded, and cleanup ignores further signals once it begins. The file is
# named and created by this shell itself, with noclobber, so its path is known
# before it exists and no child dies holding it. The deadline
# kills only a process that is still this shell's child, and it is stopped
# before this shell starts any other child. The app writes the bundled CLI's
# path in place of the placeholder when it extracts this file. Exits 0 unless
# signalled while the CLI runs: a failure here is never Claude's to report.

set -u

readonly KEY=WORKSPACES_CONVERSATIONS_DIR
lookup_out=""
lookup_client=""
lookup_guard=""
lookup_interrupted=""

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
    trap 'lookup_interrupted=1' TERM INT HUP
    start_lookup "$@"
    local started=$?
    trap end_on_signal TERM INT HUP
    [[ -z "$lookup_interrupted" ]] || end_on_signal
    ((started == 0)) || return 1
    wait "$lookup_client"
    local status=$?
    lookup_client=""
    stop_guard
    return "$status"
}

start_lookup() {
    local socket=$1 session=$2
    create_lookup_file || return 1
    PATH="$PATH:/opt/homebrew/bin:/usr/local/bin" tmux -S "$socket" \
        display-message -p -t "$session" '#{pid}' \; show-environment -t "$session" "$KEY" \
        </dev/null >"$lookup_out" 2>/dev/null &
    lookup_client=$!
    end_at_deadline "$lookup_client" </dev/null >/dev/null 2>&1 &
    lookup_guard=$!
}

create_lookup_file() {
    local attempt made
    for attempt in 1 2 3 4 5 6 7 8; do
        lookup_out="${TMPDIR:-/tmp}"
        lookup_out="${lookup_out%/}/workspaces-observer.$$.$RANDOM"
        [[ -e "$lookup_out" || -L "$lookup_out" ]] && continue
        set -C
        : 2>/dev/null >"$lookup_out"
        made=$?
        set +C
        ((made == 0)) && return 0
    done
    lookup_out=""
    return 1
}

end_on_signal() {
    trap '' TERM INT HUP
    exit 0
}

end_lookup() {
    trap '' TERM INT HUP
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
