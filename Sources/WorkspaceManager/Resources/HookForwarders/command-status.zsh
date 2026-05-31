# command-status.zsh — sourceable zsh producer for WorkSpaces command status.
#
# Usage:
#   source "$WORKSPACES_COMMAND_STATUS_ZSH"
#
# The hook emits OSC-133-shaped command lifecycle markers through the existing
# WorkSpaces Unix-socket listener. It is opt-in and safe to source from .zshrc:
# missing socket/session env, missing curl, or a stopped host app all degrade to
# no-op behavior.

if [[ -z "${ZSH_VERSION:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi

if [[ -n "${WORKSPACES_COMMAND_STATUS_ZSH_LOADED:-}" ]]; then
    return 0
fi
typeset -g WORKSPACES_COMMAND_STATUS_ZSH_LOADED=1
typeset -g __workspaces_command_status_started=0

__workspaces_post_command_marker() {
    emulate -L zsh
    setopt no_unset

    local socket="${WORKSPACES_HOOKS_SOCKET:-}"
    local host_session_id="${WORKSPACES_HOST_SESSION_ID:-}"
    local payload="$1"

    [[ -n "$socket" && -S "$socket" ]] || return 0
    [[ -n "$host_session_id" ]] || return 0
    [[ -x /usr/bin/curl ]] || return 0

    builtin printf '%b' "$payload" | /usr/bin/curl \
        --silent \
        --show-error \
        --max-time 1 \
        --unix-socket "$socket" \
        -X POST \
        -H 'Content-Type: application/octet-stream' \
        -H "X-WorkSpaces-Host-Session-ID: $host_session_id" \
        --data-binary @- \
        'http://localhost/command-markers' \
        >/dev/null 2>&1 || true
}

__workspaces_command_status_preexec() {
    emulate -L zsh
    typeset -g __workspaces_command_status_started=1
    __workspaces_post_command_marker $'\033]133;B\a'
}

__workspaces_command_status_precmd() {
    local exit_code=$?
    emulate -L zsh

    if [[ "${__workspaces_command_status_started:-0}" != "1" ]]; then
        return 0
    fi

    typeset -g __workspaces_command_status_started=0
    __workspaces_post_command_marker $'\033]133;D;'"${exit_code}"$'\a'
}

autoload -Uz add-zsh-hook 2>/dev/null || return 0
add-zsh-hook preexec __workspaces_command_status_preexec 2>/dev/null || true
if add-zsh-hook precmd __workspaces_command_status_precmd 2>/dev/null; then
    precmd_functions=(__workspaces_command_status_precmd ${precmd_functions:#__workspaces_command_status_precmd})
fi
