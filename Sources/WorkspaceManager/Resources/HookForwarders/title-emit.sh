#!/usr/bin/env bash
# title-emit.sh — Channel 3 helper installed via ClaudeSettingsInstaller.
#
# Reads a Claude Code hook payload from stdin (JSON) and emits an OSC 2 sequence
# to /dev/tty so the embedded libghostty terminal updates its tab title. Stays
# in sync with `Sources/WorkspaceManager/Resources/HookForwarders/title-emit.sh`
# in the WorkSpaces repo. Pure stdlib — no curl, jq, or python required.
#
# Hook events:
#   UserPromptSubmit → "<short prompt>"
#   Stop             → "<cwd basename> · ready"
#
# Failure mode: never block. If anything fails (no /dev/tty, malformed JSON),
# print a single space (Claude Code's accepted no-op response) and exit 0.

set -u

trap 'printf " "; exit 0' ERR

payload=""
while IFS= read -r line; do
    payload+="${line}"$'\n'
done

extract_field() {
    local key="$1"
    # Greedy single-line regex; fine for the small fields we care about.
    printf '%s' "$payload" \
        | tr '\n' ' ' \
        | sed -nE "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p" \
        | head -n 1
}

hook_event="$(extract_field 'hook_event_name')"
prompt="$(extract_field 'prompt')"
cwd="$(extract_field 'cwd')"

short_basename() {
    local path="$1"
    [ -n "$path" ] || { printf 'workspace'; return; }
    local base
    base="${path##*/}"
    [ -n "$base" ] || base="$path"
    printf '%s' "$base"
}

shorten() {
    local input="$1"
    local limit="${2:-48}"
    local trimmed
    trimmed="$(printf '%s' "$input" | tr -d '\r' | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g')"
    if [ "${#trimmed}" -gt "$limit" ]; then
        printf '%s…' "${trimmed:0:limit}"
    else
        printf '%s' "$trimmed"
    fi
}

title=""
case "$hook_event" in
    UserPromptSubmit)
        if [ -n "$prompt" ]; then
            title="$(shorten "$prompt")"
        else
            title="$(short_basename "$cwd") · thinking"
        fi
        ;;
    Stop)
        title="$(short_basename "$cwd") · ready"
        ;;
    *)
        # Unrecognized event: emit a no-op.
        printf ' '
        exit 0
        ;;
esac

if [ -z "$title" ]; then
    printf ' '
    exit 0
fi

if [ -e /dev/tty ]; then
    printf '\033]2;%s\007' "$title" > /dev/tty 2>/dev/null || true
fi

printf ' '
exit 0
