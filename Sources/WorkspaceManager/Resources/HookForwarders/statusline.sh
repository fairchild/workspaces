#!/usr/bin/env bash
#
# statusline.sh — Claude Code status-line forwarder with graceful fallback.
#
# Configured in ~/.claude/settings.json under `statusLine.command`. Claude Code
# invokes this script ~every 5 s with the current status JSON on stdin. Two
# worlds share one script, chosen by whether a live host socket is present:
#
#   * Inside the WorkSpaces app — WORKSPACES_HOOKS_SOCKET names a live socket.
#     POST the body unchanged to the host's /statusline route and print a single
#     space so the terminal row stays empty (the host owns visualization).
#
#   * Everywhere else (plain terminal, another app) — no host to render the
#     footer, so render a normal status line ourselves: delegate to the user's
#     own renderer named by WORKSPACES_STATUSLINE_FALLBACK, and if that is unset
#     or unusable, print a built-in "model · branch · dir" line.
#
# Agent update intake purpose: status-line forwarder.
#
# Hard requirements:
#   * The forward path and the built-in fallback use stdlib bash + curl/sed/git
#     only — no jq, no python. A delegated renderer may use whatever it needs.
#   * Never block the forward path; if the socket is unreachable, fall through.
#   * Always exit 0 so Claude never renders an error.
#   * Bash 3.2 safe (macOS /bin/bash): guard empty-array expansion under `set -u`.

set -u

socket="${WORKSPACES_HOOKS_SOCKET:-}"
host_session_id="${WORKSPACES_HOST_SESSION_ID:-}"

# Read the status JSON once so we can either forward it or hand it to a renderer.
body="$(cat)"

# --- Inside the WorkSpaces app: forward to the host, keep the row empty. -------
if [[ -n "$socket" && -S "$socket" ]]; then
    headers=(-H 'Content-Type: application/json')
    if [[ -n "$host_session_id" ]]; then
        headers+=(-H "X-WorkSpaces-Host-Session-ID: $host_session_id")
    fi

    printf '%s' "$body" | /usr/bin/curl \
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

# --- Outside the app: delegate to the user's own status-line renderer. ---------
fallback="${WORKSPACES_STATUSLINE_FALLBACK:-}"
if [[ -n "$fallback" ]]; then
    fallback="${fallback/#\~\//$HOME/}"
    # Split on whitespace so the value may carry arguments (e.g. "renderer --flag").
    read -r -a fallback_cmd <<<"$fallback"
    if ((${#fallback_cmd[@]})); then
        if [[ -x "${fallback_cmd[0]}" ]] || command -v "${fallback_cmd[0]}" >/dev/null 2>&1; then
            printf '%s' "$body" | "${fallback_cmd[@]}"
            exit 0
        fi
    fi
fi

# --- Built-in minimal renderer: model · branch · dir (pure bash + sed + git). --
json_str() {
    # First "key":"value" string value in $body ("" if absent).
    printf '%s' "$body" |
        /usr/bin/sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" |
        /usr/bin/head -1
}
json_num() {
    # First "key": <number> value in $body ("" if absent).
    printf '%s' "$body" |
        /usr/bin/sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\([0-9.][0-9.]*\).*/\1/p" |
        /usr/bin/head -1
}

model="$(json_str display_name)"
dir="$(json_str current_dir)"
[[ -z "$dir" ]] && dir="$(json_str cwd)"

branch=""
if [[ -n "$dir" && -d "$dir" ]]; then
    branch="$(/usr/bin/git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
fi

dir_label="${dir##*/}"

cost_raw="$(json_num total_cost_usd)"
cost=""
if [[ -n "$cost_raw" ]]; then
    cost="$(printf '$%.2f' "$cost_raw" 2>/dev/null || true)"
    [[ "$cost" == '$0.00' ]] && cost=""
fi

parts=()
[[ -n "$model" ]] && parts+=("$model")
[[ -n "$branch" ]] && parts+=("$branch")
[[ -n "$dir_label" ]] && parts+=("$dir_label")
[[ -n "$cost" ]] && parts+=("$cost")

out=""
if ((${#parts[@]})); then
    for p in "${parts[@]}"; do
        if [[ -n "$out" ]]; then
            out="$out · $p"
        else
            out="$p"
        fi
    done
fi

# Never emit an empty status line (Claude renders that as an error row).
[[ -z "$out" ]] && out=' '
printf '%s' "$out"
exit 0
