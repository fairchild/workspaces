#!/usr/bin/env bash
# stub-agent.sh — a token-free stand-in for `claude`, installed on PATH as `claude` by
# the continuity drill (scripts/continuity-evidence.sh --drill). It names a conversation,
# writes a transcript where ClaudeTranscriptResumability looks, fires the configured
# SessionStart (and turn) hooks with payloads shaped like Claude Code's, then holds its
# argv in the process table until killed so restore and the holder probe see a live agent.
# It writes only into a Claude home that carries a `.stub-agent-sandbox` marker.
set -euo pipefail

SANDBOX_MARKER=".stub-agent-sandbox"
STUB_MODEL="stub-agent"

CONVERSATION_ID=""
RESUME_ID=""
SESSION_ID_ARG=""
EFFORT=""
MODEL="$STUB_MODEL"
PROMPT=""
SOURCE="startup"
CLAUDE_HOME=""
WORKING_DIRECTORY=""
TRANSCRIPT=""
LEDGER=""
TURN="${STUB_AGENT_TURN:-done}"
HOLD_SECONDS="${STUB_AGENT_HOLD_SECONDS:-}"
SLEEP_PID=""

main() {
    parse_args "$@"
    resolve_claude_home
    require_sandbox_marker
    resolve_conversation
    announce_start
    fire_hooks SessionStart "$(session_start_payload)"
    take_turn
    record_in_ledger
    show_input_box
    hold
}

usage() {
    cat <<'USAGE'
Usage: claude [--session-id <uuid> | --resume <uuid>] [--effort <level>] [--model <name>] [prompt...]

A stub of Claude Code for the continuity drill. It spends no tokens and talks to no API.

Environment:
  CLAUDE_CONFIG_DIR         Claude home (default: $HOME/.claude). Must contain .stub-agent-sandbox.
  STUB_AGENT_TURN           done (default) writes a finished turn; held writes the prompt and never
                            stops, like an agent mid-turn; none writes no turn.
  STUB_AGENT_HOLD_SECONDS   exit after this many seconds instead of holding until killed.
USAGE
}

parse_args() {
    local -a prompt_words=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --session-id)
                [[ $# -ge 2 ]] || die 2 "--session-id requires a value"
                SESSION_ID_ARG="$2"
                shift 2
                ;;
            --resume | -r)
                [[ $# -ge 2 ]] || die 2 "$1 requires a value"
                RESUME_ID="$2"
                shift 2
                ;;
            --effort)
                [[ $# -ge 2 ]] || die 2 "--effort requires a value"
                EFFORT="$2"
                shift 2
                ;;
            --model)
                [[ $# -ge 2 ]] || die 2 "--model requires a value"
                MODEL="$2"
                shift 2
                ;;
            --help | -h)
                usage
                exit 0
                ;;
            --)
                shift
                prompt_words+=("$@")
                break
                ;;
            -*)
                echo "stub-agent: ignoring unsupported flag $1" >&2
                shift
                ;;
            *)
                prompt_words+=("$1")
                shift
                ;;
        esac
    done
    [[ -z "$SESSION_ID_ARG" || -z "$RESUME_ID" ]] || die 2 "--session-id and --resume name different conversations"
    PROMPT="${prompt_words[*]:-drill turn}"
    case "$TURN" in
        done | held | none) ;;
        *) die 2 "STUB_AGENT_TURN must be done, held or none (got '$TURN')" ;;
    esac
}

die() {
    local code="$1"
    shift
    echo "stub-agent: $*" >&2
    exit "$code"
}

resolve_claude_home() {
    local configured="${CLAUDE_CONFIG_DIR:-}"
    configured="${configured#"${configured%%[![:space:]]*}"}"
    configured="${configured%"${configured##*[![:space:]]}"}"
    if [[ "$configured" == "~"* ]]; then
        CLAUDE_HOME="$HOME${configured#\~}"
    elif [[ -n "$configured" ]]; then
        CLAUDE_HOME="$configured"
    else
        CLAUDE_HOME="$HOME/.claude"
    fi
    LEDGER="$CLAUDE_HOME/stub-agent-ledger.jsonl"
}

require_sandbox_marker() {
    [[ -f "$CLAUDE_HOME/$SANDBOX_MARKER" ]] \
        || die 78 "refusing to write into $CLAUDE_HOME: it has no $SANDBOX_MARKER marker, so it may be a real Claude home"
}

resolve_conversation() {
    WORKING_DIRECTORY="$(pwd -P)"
    local project_dir="$CLAUDE_HOME/projects/${WORKING_DIRECTORY//[^A-Za-z0-9]/-}"
    if [[ -n "$RESUME_ID" ]]; then
        CONVERSATION_ID="$RESUME_ID"
        SOURCE="resume"
        TRANSCRIPT="$project_dir/$CONVERSATION_ID.jsonl"
        [[ -f "$TRANSCRIPT" ]] || die 1 "No conversation found with session ID: $CONVERSATION_ID"
        return
    fi
    CONVERSATION_ID="${SESSION_ID_ARG:-$(new_uuid)}"
    TRANSCRIPT="$project_dir/$CONVERSATION_ID.jsonl"
    [[ ! -e "$TRANSCRIPT" ]] || die 1 "Session ID $CONVERSATION_ID is already in use."
    mkdir -p "$project_dir"
}

new_uuid() {
    uuidgen | tr '[:upper:]' '[:lower:]'
}

timestamp() {
    date -u +%Y-%m-%dT%H:%M:%S.000Z
}

announce_start() {
    echo "stub-agent ($SOURCE) conversation=$CONVERSATION_ID effort=${EFFORT:-default} turn=$TURN"
    echo "transcript: $TRANSCRIPT"
}

session_start_payload() {
    jq -nc \
        --arg session_id "$CONVERSATION_ID" \
        --arg transcript_path "$TRANSCRIPT" \
        --arg cwd "$WORKING_DIRECTORY" \
        --arg source "$SOURCE" \
        --arg model "$MODEL" \
        '{session_id: $session_id, transcript_path: $transcript_path, cwd: $cwd,
          hook_event_name: "SessionStart", source: $source, model: $model}'
}

user_prompt_payload() {
    jq -nc \
        --arg session_id "$CONVERSATION_ID" \
        --arg transcript_path "$TRANSCRIPT" \
        --arg cwd "$WORKING_DIRECTORY" \
        --arg prompt "$PROMPT" \
        '{session_id: $session_id, transcript_path: $transcript_path, cwd: $cwd,
          hook_event_name: "UserPromptSubmit", permission_mode: "default", prompt: $prompt}'
}

stop_payload() {
    jq -nc \
        --arg session_id "$CONVERSATION_ID" \
        --arg transcript_path "$TRANSCRIPT" \
        --arg cwd "$WORKING_DIRECTORY" \
        '{session_id: $session_id, transcript_path: $transcript_path, cwd: $cwd,
          hook_event_name: "Stop", permission_mode: "default", stop_hook_active: false}'
}

fire_hooks() {
    local event="$1"
    local payload="$2"
    local settings="$CLAUDE_HOME/settings.json"
    [[ -f "$settings" ]] || return 0
    local command
    while IFS= read -r command; do
        [[ -n "$command" ]] || continue
        /bin/sh -c "$command" <<<"$payload" >/dev/null 2>&1 || true
        record_hook "$event" "$command"
    done < <(hook_commands "$event" "$settings")
}

hook_commands() {
    jq -r --arg event "$1" --arg source "$SOURCE" '
        .hooks[$event][]?
        | select((.matcher // "") as $m | $m == "" or $m == "*" or ($source | test($m)))
        | .hooks[]?
        | select(.type == "command")
        | .command' "$2" 2>/dev/null || true
}

record_hook() {
    jq -nc \
        --arg event "hook" \
        --arg hook "$1" \
        --arg command "$2" \
        --arg conversation_id "$CONVERSATION_ID" \
        --arg hooks_socket "${WORKSPACES_HOOKS_SOCKET:-}" \
        --arg at "$(timestamp)" \
        '{event: $event, hook: $hook, command: $command, conversation_id: $conversation_id,
          hooks_socket: $hooks_socket, at: $at}' >>"$LEDGER"
}

take_turn() {
    [[ "$TURN" != none ]] || return 0
    local user_uuid
    user_uuid="$(new_uuid)"
    append_user_entry "$user_uuid"
    fire_hooks UserPromptSubmit "$(user_prompt_payload)"
    [[ "$TURN" == "done" ]] || return 0
    append_assistant_entry "$user_uuid"
    fire_hooks Stop "$(stop_payload)"
}

append_user_entry() {
    jq -nc \
        --arg uuid "$1" \
        --arg session_id "$CONVERSATION_ID" \
        --arg cwd "$WORKING_DIRECTORY" \
        --arg prompt "$PROMPT" \
        --arg timestamp "$(timestamp)" \
        '{parentUuid: null, isSidechain: false, type: "user",
          message: {role: "user", content: $prompt},
          uuid: $uuid, timestamp: $timestamp, sessionId: $session_id, cwd: $cwd, version: "stub-agent"}' \
        >>"$TRANSCRIPT"
}

append_assistant_entry() {
    jq -nc \
        --arg parent "$1" \
        --arg uuid "$(new_uuid)" \
        --arg session_id "$CONVERSATION_ID" \
        --arg cwd "$WORKING_DIRECTORY" \
        --arg model "$MODEL" \
        --arg effort "$EFFORT" \
        --arg timestamp "$(timestamp)" \
        '{parentUuid: $parent, isSidechain: false, type: "assistant",
          message: {model: $model, role: "assistant", content: [{type: "text", text: "stub reply"}]},
          uuid: $uuid, timestamp: $timestamp, sessionId: $session_id, cwd: $cwd, version: "stub-agent"}
         + (if $effort == "" then {} else {effort: $effort} end)' \
        >>"$TRANSCRIPT"
}

record_in_ledger() {
    jq -nc \
        --arg event "start" \
        --argjson pid "$$" \
        --arg conversation_id "$CONVERSATION_ID" \
        --arg source "$SOURCE" \
        --arg cwd "$WORKING_DIRECTORY" \
        --arg transcript "$TRANSCRIPT" \
        --arg effort "$EFFORT" \
        --arg model "$MODEL" \
        --arg turn "$TURN" \
        --arg host_session_id "${WORKSPACES_HOST_SESSION_ID:-}" \
        --arg hooks_socket "${WORKSPACES_HOOKS_SOCKET:-}" \
        --arg tmux "${TMUX:-}" \
        --arg at "$(timestamp)" \
        '{event: $event, pid: $pid, conversation_id: $conversation_id, source: $source, cwd: $cwd,
          transcript: $transcript, effort: $effort, model: $model, turn: $turn,
          host_session_id: $host_session_id, hooks_socket: $hooks_socket, tmux: $tmux, at: $at}' \
        >>"$LEDGER"
}

show_input_box() {
    echo "────────────────────────────────────────"
    printf '❯ '
}

hold() {
    trap stop_holding TERM HUP INT
    if [[ -n "$HOLD_SECONDS" ]]; then
        sleep "$HOLD_SECONDS" &
        SLEEP_PID=$!
        wait "$SLEEP_PID" || true
        echo
        return 0
    fi
    while :; do
        sleep 3600 &
        SLEEP_PID=$!
        wait "$SLEEP_PID" || true
    done
}

stop_holding() {
    [[ -z "$SLEEP_PID" ]] || kill "$SLEEP_PID" 2>/dev/null || true
    exit 0
}

main "$@"
