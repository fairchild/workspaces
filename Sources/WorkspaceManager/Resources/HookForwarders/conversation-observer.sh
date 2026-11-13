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
# descriptor to the server, so a stopped server would hold a pipe open. The
# file sits in a private directory this shell names before `mkdir -m 700`
# makes it: mkdir refuses any existing path, links included, and the shell
# knows the name even if mkdir dies. Only a directory mkdir reported making
# is emptied. A name it did not report may still be a directory a killed
# mkdir made, so it is removed only while it is an empty directory of ours
# and not a link: what someone else put there stays. The client writes the
# file under umask 077. One owner cleans up the lookup's directory, client
# and deadline, on return or on any signal; a signal while they are being
# started waits until all three are recorded, and cleanup ignores further
# signals once it begins.
# The deadline kills only a process that is still this shell's child, and it
# is stopped before this shell starts any other child. The app writes the
# bundled CLI's path in place of the placeholder when it extracts this file.
# Exits 0 unless signalled while the CLI runs: a failure here is never
# Claude's to report.

set -u

readonly KEY=WORKSPACES_CONVERSATIONS_DIR
lookup_dir=""
lookup_dir_acquired=""
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
    create_lookup_dir || return 1
    (
        umask 077
        PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
        exec tmux -S "$socket" \
            display-message -p -t "$session" '#{pid}' \; show-environment -t "$session" "$KEY" \
            </dev/null >"$lookup_out" 2>/dev/null
    ) &
    lookup_client=$!
    end_at_deadline "$lookup_client" </dev/null >/dev/null 2>&1 &
    lookup_guard=$!
}

create_lookup_dir() {
    local attempt
    for attempt in 1 2 3 4 5 6 7 8; do
        lookup_dir="${TMPDIR:-/tmp}"
        lookup_dir="${lookup_dir%/}/workspaces-observer.$$.$RANDOM"
        if mkdir -m 700 "$lookup_dir" 2>/dev/null; then
            lookup_dir_acquired=1
            lookup_out="$lookup_dir/out"
            return 0
        fi
        [[ -z "$lookup_interrupted" ]] || return 1
    done
    lookup_dir=""
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
    if [[ -n "$lookup_dir_acquired" ]]; then
        rm -f "$lookup_dir/out"
        rmdir "$lookup_dir" 2>/dev/null
    elif [[ -n "$lookup_dir" && -d "$lookup_dir" && ! -L "$lookup_dir" && -O "$lookup_dir" ]]; then
        rmdir "$lookup_dir" 2>/dev/null
    fi
    lookup_dir=""
    lookup_dir_acquired=""
    lookup_out=""
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
