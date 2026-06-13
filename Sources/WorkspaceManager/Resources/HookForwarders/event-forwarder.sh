#!/usr/bin/env bash
#
# event-forwarder.sh — Claude Code hook event forwarder.
#
# Configured in ~/.claude/settings.json under
# `hooks.<EventName>[*].hooks[*]` as `{type: "command", command: "<this script>"}`.
# Claude Code invokes this script with the hook payload JSON on stdin. We POST
# the body unchanged to the host's Unix socket on /event, then exit 0.
#
# Why a command-hook forwarder instead of a `type: "http"` hook?
# Real Claude Code does not speak the `http+unix://` URL scheme — POSTing such
# a URL fails with `Unsupported protocol http+unix:` and the entire hook
# pipeline errors. curl, however, supports `--unix-socket`, so we pipe through
# it from a small command-hook script. Same pattern as `statusline.sh`.
#
# Agent update intake purpose: command hook forwarder.
#
# Hard requirements:
#   * stdlib bash + curl only — no jq, no python.
#   * Never block; if the socket is unreachable, drop the payload and exit 0.
#   * Exit 0 even on transport failure so Claude doesn't render a hook error.

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
        'http://localhost/event' \
        >/dev/null 2>&1 || true
else
    # No socket means the host isn't running or the env var didn't propagate.
    # Drain stdin so Claude doesn't block on the pipe.
    cat >/dev/null 2>&1 || true
fi

exit 0
