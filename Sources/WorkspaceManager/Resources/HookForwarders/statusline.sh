#!/usr/bin/env bash
#
# statusline.sh — Claude Code status-line forwarder.
#
# Configured in ~/.claude/settings.json under `statusLine.command`. Claude Code
# invokes this script ~every 5 s with the current status JSON on stdin. When the
# WorkSpaces host socket is reachable, we POST the body unchanged to /statusline
# and print a single space so the terminal status row stays empty (the host owns
# visualization). Without a socket — a plain terminal outside WorkSpaces — we
# render a one-line status ourselves: model, cwd, git branch, context left.
#
# Agent update intake purpose: status-line forwarder.
#
# Ownership: ClaudeIntegrationLifecycle re-extracts this script to
# ~/.local/share/workspaces/hook-forwarders/ on every app launch, overwriting
# the installed copy. Edit this file, not the installed one. Docs:
# docs/development/claude-code-integration.md § "Status-Line Forwarder".
#
# Hard requirements:
#   * stdlib bash + curl + sed + git only — no jq, no python.
#   * Never block; if the socket is unreachable, drop the payload and exit 0.
#   * Always print something and exit 0 so Claude doesn't render an error.

set -u

socket="${WORKSPACES_HOOKS_SOCKET:-}"
host_session_id="${WORKSPACES_HOST_SESSION_ID:-}"

input="$(cat 2>/dev/null || true)"

# Extracts a JSON string value and unescapes `\/` — some emitters escape
# forward slashes, which would otherwise break path checks below.
json_string() {
    printf '%s' "$1" | sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed 's/\\\//\//g'
}

json_number() {
    printf '%s' "$1" | sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*\(-\{0,1\}[0-9][0-9.]*\).*/\1/p'
}

if [[ -n "$socket" && -S "$socket" ]]; then
    headers=(-H 'Content-Type: application/json')
    if [[ -n "$host_session_id" ]]; then
        headers+=(-H "X-WorkSpaces-Host-Session-ID: $host_session_id")
    fi

    printf '%s' "$input" | /usr/bin/curl \
        --silent \
        --show-error \
        --max-time 1 \
        --unix-socket "$socket" \
        -X POST \
        "${headers[@]}" \
        --data-binary @- \
        'http://localhost/statusline' \
        >/dev/null 2>&1 || true

    printf ' '
    exit 0
fi

# Fallback rendering for terminals not running under the WorkSpaces host.
line="$(printf '%s' "$input" | tr -d '\n\r')"

model="$(json_string "$line" 'display_name')"

dir="$(json_string "$line" 'current_dir')"
if [[ -z "$dir" ]]; then
    dir="$(json_string "$line" 'cwd')"
fi
display_dir="$dir"
if [[ -n "$dir" && "$dir" == "$HOME"* ]]; then
    display_dir="~${dir#"$HOME"}"
fi

branch=""
if [[ -n "$dir" && -d "$dir" ]]; then
    branch="$(git --no-optional-locks -C "$dir" branch --show-current 2>/dev/null || true)"
fi

context=""
remaining="$(json_number "$line" 'remaining_percentage')"
used="$(json_number "$line" 'used_percentage')"
if [[ -n "$remaining" ]]; then
    context="Context: ${remaining}% remaining"
elif [[ -n "$used" ]]; then
    context="Context: ${used}% used"
fi

status=""
add_part() {
    if [[ -z "$1" ]]; then
        return 0
    fi
    if [[ -n "$status" ]]; then
        status="$status | $1"
    else
        status="$1"
    fi
}

add_part "$model"
add_part "$display_dir"
add_part "$branch"
add_part "$context"

if [[ -n "$status" ]]; then
    printf '%s' "$status"
else
    printf ' '
fi
exit 0
