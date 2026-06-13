#!/usr/bin/env bash
#
# statusline.sh — Claude Code status-line forwarder.
#
# Configured in ~/.claude/settings.json under `statusLine.command`. Claude Code
# invokes this script ~every 5 s with the current status JSON on stdin. We POST
# the body unchanged to the host's Unix socket on /statusline, then print a
# single space so the terminal status row stays empty (the host owns
# visualization).
#
# Agent update intake purpose: status-line forwarder.
#
# Hard requirements:
#   * stdlib bash + curl only — no jq, no python.
#   * Never block; if the socket is unreachable, drop the payload and exit 0.
#   * Always print a single space and exit 0 so Claude doesn't render an error.

set -u

socket="${WORKSPACES_HOOKS_SOCKET:-}"
host_session_id="${WORKSPACES_HOST_SESSION_ID:-}"

if [[ -n "$socket" && -S "$socket" ]]; then
    headers=(-H 'Content-Type: application/json')
    if [[ -n "$host_session_id" ]]; then
        headers+=(-H "X-WorkSpaces-Host-Session-ID: $host_session_id")
    fi

    /usr/bin/curl \
        --silent \
        --show-error \
        --max-time 1 \
        --unix-socket "$socket" \
        -X POST \
        "${headers[@]}" \
        --data-binary @- \
        'http://localhost/statusline' \
        >/dev/null 2>&1 || true
else
    # No socket means the host isn't running or the env var didn't propagate.
    # Drain stdin so Claude doesn't block on the pipe.
    cat >/dev/null 2>&1 || true
fi

printf ' '
exit 0
