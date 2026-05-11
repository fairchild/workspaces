#!/usr/bin/env bash
# ==========================================================================
# claude-integration-smoke.sh - Interactive evidence harness for Claude Code
# ==========================================================================
#
# This harness automates the repeatable parts of the Claude Code integration
# smoke and prompts for the parts that must be human-driven in a real terminal:
# accepting the Settings merge, driving a real Claude permission prompt, and
# opening the conversation log surface.
#
# Usage:
#   ./scripts/claude-integration-smoke.sh --pr 455 --no-build
#   ./scripts/claude-integration-smoke.sh --pr 455 --no-build --fixture-home
#   ./scripts/claude-integration-smoke.sh --non-interactive --no-build
#   ./scripts/claude-integration-smoke.sh --use-existing --deterministic-signal --host-session-id <uuid> --pr 473
#
# ==========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PR_NUMBER=""
OUTPUT_ROOT="$REPO_ROOT/output/claude-integration-smoke"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
RUN_DIR=""
NO_BUILD=false
NO_ACTIVATE=true
CLEAN_DATA=false
TRUST_MISE=false
FIXTURE_HOME=false
NON_INTERACTIVE=false
DETERMINISTIC_SIGNAL=false
USE_EXISTING=false
POST_COMMENT=false
WINDOW_TIMEOUT_SECONDS=15
ENV_FILE=""
APP_LOG=""
APP_PID=""
SOCKET_PATH=""
HOST_SESSION_ID="${WORKSPACES_HOST_SESSION_ID:-}"
SIGNAL_CWD="$PWD"
COMMENT_FILE=""
URL_FILE=""

log() {
    echo "[$(date +%H:%M:%S)] $*"
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
Usage: ./scripts/claude-integration-smoke.sh [options]

Options:
  --pr <number>          Upload captured screenshots as evidence for this PR.
  --output-dir <path>    Write artifacts under this directory.
                         Default: output/claude-integration-smoke/<timestamp>
  --no-build             Reuse the current debug binary.
  --activate             Allow the app to foreground itself and allow full-screen fallback capture.
  --clean-data           Clear the launch-dev data dir before launching.
  --fixture-home         Launch with an isolated HOME containing a fixture ~/.claude/settings.json.
                         Useful for merge-preview evidence without touching the real Claude config.
  --non-interactive      Run only automated preflight: launch, socket discovery, /healthz, screenshot.
  --deterministic-signal Send a deterministic Claude Notification hook through the installed
                         event-forwarder.sh and capture the resulting native awaiting-input state.
                         Requires a registered host session via --host-session-id or
                         WORKSPACES_HOST_SESSION_ID.
  --host-session-id <id> Host terminal session UUID to route the deterministic signal to.
                         Embedded WorkSpaces terminals export WORKSPACES_HOST_SESSION_ID.
  --signal-cwd <path>    cwd to include in deterministic hook payloads (default: current directory).
  --use-existing         Reuse a running debug app instead of launching a new one.
  --app-pid <pid>        PID to use for exact-window capture when --use-existing is set.
  --socket-path <path>   Hook listener socket path when --use-existing is set.
                         Defaults to WORKSPACES_HOOKS_SOCKET, then the stable dev socket path.
  --post-comment         Post the generated smoke evidence comment to the PR. Requires --pr.
  --env-file <path>      Source evidence token from a specific env file.
                         Defaults to ~/code/workspaces/.env when present, then repo .env.
  --trust-mise           Trust this repo's .mise.toml before building.
  --window-timeout <s>   Require a visible app window within this many seconds (default: 15).
  -h, --help             Show this help.

The script leaves the debug app running so you can continue manual follow-up.
USAGE
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pr)
                [[ $# -ge 2 ]] || fail "--pr requires a value"
                PR_NUMBER="$2"
                shift 2
                ;;
            --output-dir)
                [[ $# -ge 2 ]] || fail "--output-dir requires a value"
                OUTPUT_ROOT="$2"
                shift 2
                ;;
            --no-build)
                NO_BUILD=true
                shift
                ;;
            --activate)
                NO_ACTIVATE=false
                shift
                ;;
            --clean-data)
                CLEAN_DATA=true
                shift
                ;;
            --fixture-home)
                FIXTURE_HOME=true
                shift
                ;;
            --non-interactive)
                NON_INTERACTIVE=true
                shift
                ;;
            --deterministic-signal)
                DETERMINISTIC_SIGNAL=true
                shift
                ;;
            --host-session-id)
                [[ $# -ge 2 ]] || fail "--host-session-id requires a value"
                HOST_SESSION_ID="$2"
                shift 2
                ;;
            --signal-cwd)
                [[ $# -ge 2 ]] || fail "--signal-cwd requires a value"
                SIGNAL_CWD="$2"
                shift 2
                ;;
            --use-existing)
                USE_EXISTING=true
                shift
                ;;
            --app-pid)
                [[ $# -ge 2 ]] || fail "--app-pid requires a value"
                APP_PID="$2"
                shift 2
                ;;
            --socket-path)
                [[ $# -ge 2 ]] || fail "--socket-path requires a value"
                SOCKET_PATH="$2"
                shift 2
                ;;
            --post-comment)
                POST_COMMENT=true
                shift
                ;;
            --env-file)
                [[ $# -ge 2 ]] || fail "--env-file requires a value"
                ENV_FILE="$2"
                shift 2
                ;;
            --trust-mise)
                TRUST_MISE=true
                shift
                ;;
            --window-timeout)
                [[ $# -ge 2 ]] || fail "--window-timeout requires a value"
                WINDOW_TIMEOUT_SECONDS="$2"
                shift 2
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                fail "Unknown argument: $1"
                ;;
        esac
    done

    if [[ "$POST_COMMENT" == true && -z "$PR_NUMBER" ]]; then
        fail "--post-comment requires --pr"
    fi

    if [[ "$USE_EXISTING" == true && "$FIXTURE_HOME" == true ]]; then
        fail "--use-existing cannot be combined with --fixture-home"
    fi

    if [[ "$DETERMINISTIC_SIGNAL" == true && "$USE_EXISTING" != true ]]; then
        fail "--deterministic-signal targets an already-registered terminal; pass --use-existing with --host-session-id"
    fi
}

prepare_run_dir() {
    if [[ "$OUTPUT_ROOT" == "$REPO_ROOT/output/claude-integration-smoke" ]]; then
        RUN_DIR="$OUTPUT_ROOT/$RUN_ID"
    else
        RUN_DIR="$OUTPUT_ROOT"
    fi
    mkdir -p "$RUN_DIR"
    URL_FILE="$RUN_DIR/evidence-urls.md"
    COMMENT_FILE="$RUN_DIR/pr-comment.md"
    : >"$URL_FILE"
}

source_env_if_available() {
    if [[ -n "${EVIDENCE_UPLOAD_TOKEN:-}" ]]; then
        return
    fi

    local candidate=""
    if [[ -n "$ENV_FILE" ]]; then
        candidate="$ENV_FILE"
    elif [[ -f "$HOME/code/workspaces/.env" ]]; then
        candidate="$HOME/code/workspaces/.env"
    elif [[ -f "$REPO_ROOT/.env" ]]; then
        candidate="$REPO_ROOT/.env"
    fi

    if [[ -n "$candidate" && -f "$candidate" ]]; then
        log "Sourcing evidence env: $candidate"
        set -a
        # shellcheck disable=SC1090
        source "$candidate"
        set +a
    fi
}

write_fixture_home() {
    local fixture_home="$RUN_DIR/fixture-home"
    mkdir -p "$fixture_home/.claude"
    cat >"$fixture_home/.claude/settings.json" <<'JSON'
{
  "existingKey": "existingValue",
  "theme": "dark"
}
JSON
    printf "%s\n" "$fixture_home"
}

launch_app() {
    local -a launch_args=("--window-timeout" "$WINDOW_TIMEOUT_SECONDS")
    [[ "$NO_BUILD" == true ]] && launch_args+=("--no-build")
    [[ "$NO_ACTIVATE" == true ]] && launch_args+=("--no-activate")
    [[ "$CLEAN_DATA" == true ]] && launch_args+=("--clean-data")
    [[ "$TRUST_MISE" == true ]] && launch_args+=("--trust-mise")

    if [[ "$FIXTURE_HOME" == true ]]; then
        local fixture_home
        fixture_home="$(write_fixture_home)"
        launch_args+=("--env" "HOME=$fixture_home")
        log "Using fixture HOME: $fixture_home"
    fi

    local launcher_log="$RUN_DIR/launch-dev-wrapper.log"
    log "Launching debug app..."
    (
        cd "$REPO_ROOT"
        ./scripts/launch-dev.sh "${launch_args[@]}"
    ) | tee "$launcher_log"

    APP_LOG="$(
        sed -nE 's/^\[[0-9:]+\] Log file: (.*)$/\1/p' "$launcher_log" | tail -n 1
    )"
    [[ -n "$APP_LOG" && -f "$APP_LOG" ]] || fail "Could not discover launch log from $launcher_log"

    APP_PID="$(
        sed -nE 's/^\[[0-9:]+\] WorkspaceManager running \(pid=([0-9]+)\).*$/\1/p' "$launcher_log" | tail -n 1
    )"

    log "Launch log: $APP_LOG"
    if [[ -n "$APP_PID" ]]; then
        log "App pid: $APP_PID"
    fi
}

adopt_existing_app() {
    if [[ -z "$SOCKET_PATH" ]]; then
        SOCKET_PATH="${WORKSPACES_HOOKS_SOCKET:-}"
    fi
    if [[ -z "$SOCKET_PATH" ]]; then
        SOCKET_PATH="$HOME/Library/Application Support/com.cloudcompute.workspaces/hooks.sock"
    fi

    [[ -S "$SOCKET_PATH" ]] || fail "Hook socket is not live: $SOCKET_PATH"

    if [[ -n "$APP_PID" ]]; then
        if ! ps -p "$APP_PID" >/dev/null 2>&1; then
            fail "No running process for --app-pid $APP_PID"
        fi
        log "Using existing app pid: $APP_PID"
    else
        log "Using existing app without pid-filtered capture."
    fi
    log "Hook socket: $SOCKET_PATH"
}

discover_socket() {
    local deadline=$((SECONDS + 10))
    local socket=""

    while (( SECONDS < deadline )); do
        socket="$(
            sed -nE 's/.*listener started at (.*hooks\.sock).*/\1/p' "$APP_LOG" | tail -n 1
        )"
        if [[ -n "$socket" && -S "$socket" ]]; then
            SOCKET_PATH="$socket"
            log "Hook socket: $SOCKET_PATH"
            return
        fi
        sleep 1
    done

    fail "Could not find live hooks.sock in $APP_LOG"
}

probe_healthz() {
    local body
    body="$(curl --silent --show-error --unix-socket "$SOCKET_PATH" http://unix/healthz)"
    [[ "$body" == "OK" ]] || fail "Unexpected /healthz response: $body"
    printf "%s\n" "$body" >"$RUN_DIR/healthz.txt"
    log "Hook listener /healthz: OK"
}

capture_step() {
    local slug="$1"
    local description="$2"
    local screenshot="$RUN_DIR/${slug}.png"
    local url=""

    log "Capture: $slug - $description"
    local -a capture_args=("--output" "$screenshot")
    if [[ -n "$APP_PID" ]]; then
        capture_args+=("--pid" "$APP_PID")
    fi

    if ! (
        cd "$REPO_ROOT"
        ./scripts/capture-window.sh "${capture_args[@]}"
    ) >"$RUN_DIR/${slug}.capture.log" 2>&1; then
        if [[ "$NO_ACTIVATE" == true ]]; then
            fail "Window capture failed for $slug. Keep the debug app visible, or rerun with --activate. See $RUN_DIR/${slug}.capture.log"
        fi
        log "Window capture failed; using full-screen fallback because --activate was set."
        screencapture -x "$screenshot"
    fi

    if [[ -n "$PR_NUMBER" ]]; then
        if [[ -z "${EVIDENCE_UPLOAD_TOKEN:-}" ]]; then
            log "EVIDENCE_UPLOAD_TOKEN is not set; keeping local screenshot only."
        else
            url="$(
                cd "$REPO_ROOT"
                ./scripts/evidence.sh --pr "$PR_NUMBER" --name "claude-integration-$slug" --file "$screenshot"
            )"
        fi
    fi

    if [[ -n "$url" ]]; then
        printf -- "- ![%s](%s) - %s\n" "$slug" "$url" "$description" >>"$URL_FILE"
    else
        printf -- "- %s - %s (%s)\n" "$slug" "$description" "$screenshot" >>"$URL_FILE"
    fi
}

json_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    printf "%s" "$value"
}

validate_host_session_id() {
    local uuid_re='^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
    if [[ -z "$HOST_SESSION_ID" ]]; then
        fail "--deterministic-signal requires --host-session-id or WORKSPACES_HOST_SESSION_ID from an embedded WorkSpaces terminal"
    fi
    if [[ ! "$HOST_SESSION_ID" =~ $uuid_re ]]; then
        fail "Invalid host session UUID: $HOST_SESSION_ID"
    fi
}

event_forwarder_path() {
    local socket_dir
    socket_dir="$(dirname "$SOCKET_PATH")"
    printf "%s/HookForwarders/event-forwarder.sh" "$socket_dir"
}

send_forwarder_payload() {
    local payload_file="$1"
    local forwarder
    forwarder="$(event_forwarder_path)"
    [[ -x "$forwarder" ]] || fail "Installed event forwarder is not executable: $forwarder"

    WORKSPACES_HOOKS_SOCKET="$SOCKET_PATH" \
        WORKSPACES_HOST_SESSION_ID="$HOST_SESSION_ID" \
        "$forwarder" <"$payload_file" >"$RUN_DIR/$(basename "$payload_file" .json).forwarder.log" 2>&1
}

run_deterministic_signal() {
    validate_host_session_id

    local agent_session_id="deterministic-signal-$RUN_ID"
    local escaped_session_id
    local escaped_cwd
    escaped_session_id="$(json_escape "$agent_session_id")"
    escaped_cwd="$(json_escape "$SIGNAL_CWD")"

    local session_start="$RUN_DIR/deterministic-session-start.json"
    local notification="$RUN_DIR/deterministic-notification.json"

    printf '{"hook_event_name":"SessionStart","session_id":"%s","cwd":"%s"}\n' \
        "$escaped_session_id" \
        "$escaped_cwd" \
        >"$session_start"

    printf '{"hook_event_name":"Notification","session_id":"%s","cwd":"%s","notification_type":"permission_prompt","title":"WorkSpaces deterministic signal","message":"event-forwarder.sh reached the native app"}\n' \
        "$escaped_session_id" \
        "$escaped_cwd" \
        >"$notification"

    {
        printf "socket=%s\n" "$SOCKET_PATH"
        printf "host_session_id=%s\n" "$HOST_SESSION_ID"
        printf "signal_cwd=%s\n" "$SIGNAL_CWD"
        printf "forwarder=%s\n" "$(event_forwarder_path)"
        printf "agent_session_id=%s\n" "$agent_session_id"
    } >"$RUN_DIR/deterministic-signal.env"

    log "Sending deterministic SessionStart through event-forwarder.sh"
    send_forwarder_payload "$session_start"
    log "Sending deterministic permission_prompt Notification through event-forwarder.sh"
    send_forwarder_payload "$notification"

    sleep 1
    capture_step "02-deterministic-signal" "Installed event-forwarder.sh delivered a Claude permission_prompt hook to the native app."
}

wait_for_user() {
    local prompt="$1"
    printf "\n%s\n" "$prompt"
    read -r -p "Press Return to capture, or type 'skip' to skip this step: " reply
    [[ "$reply" != "skip" ]]
}

run_interactive_steps() {
    capture_step "01-app-launched" "Debug app launched; hook listener health check passed."

    if wait_for_user "Open Settings -> Agents. Leave the Claude Code integration toggle off."; then
        capture_step "02-agents-toggle-off" "Settings Agents pane before enabling the Claude Code integration."
    fi

    if wait_for_user "Toggle on 'Send Claude Code status to WorkSpaces' so the merge preview sheet is visible. Do not accept until after this capture."; then
        capture_step "03-merge-preview" "Non-destructive ~/.claude/settings.json merge preview."
    fi

    if wait_for_user "Accept the merge preview. Wait for the status row to show the installed settings path and backup."; then
        capture_step "04-post-install-status" "Settings install completed with path, modified time, and latest backup visible."
    fi

    if wait_for_user "Open a workspace terminal, run claude, and drive a permission prompt. Capture while the sidebar state is awaiting input."; then
        capture_step "05-awaiting-permission" "Real Claude session reached awaiting-input / permission state."
    fi

    if wait_for_user "Accept or reject the Claude permission and stop the run. Capture once the session returns to complete/idle."; then
        capture_step "06-complete-state" "Real Claude session completed and UI state settled."
    fi

    if wait_for_user "From the embedded terminal, run: printf '\\e]9;Permission required from OSC fallback\\a' > \$(tty). Capture after the fallback state appears."; then
        capture_step "07-osc-fallback" "OSC notification fallback produced host UI state without a matching hook event."
    fi

    if wait_for_user "Open the conversation log for the active Claude session."; then
        capture_step "08-conversation-log" "Conversation log renders the live transcript surface."
    fi

}

write_comment_file() {
    local date_string
    date_string="$(date '+%Y-%m-%d')"

    local behaviors
    if [[ "$DETERMINISTIC_SIGNAL" == true ]]; then
        behaviors="- The stable hook listener socket answers \`/healthz\`.
- The installed \`event-forwarder.sh\` posted a deterministic Claude \`SessionStart\`.
- The installed \`event-forwarder.sh\` posted a deterministic Claude \`Notification(permission_prompt)\`.
- The native app rendered the routed host session in awaiting-input state."
    elif [[ "$NON_INTERACTIVE" == true ]]; then
        behaviors="- Debug app launches.
- The stable hook listener socket is discovered from launch logs.
- The hook listener answers \`/healthz\`.
- A screenshot of the launched debug app was captured."
    else
        behaviors="- Debug app launches and the stable hook listener answers \`/healthz\`.
- Settings -> Agents renders the merge preview and installs with backup visibility.
- A real Claude terminal session can drive awaiting-input and completion UI states.
- OSC fallback can update host state when no matching hook event arrives.
- Conversation log renders transcript data when captured above."
    fi

    cat >"$COMMENT_FILE" <<EOF
## Manual Claude integration smoke evidence

Captured against the interactive Claude Code integration on ${date_string}.

$(cat "$URL_FILE")

Behaviors covered:
${behaviors}

Local artifact bundle: \`${RUN_DIR}\`
EOF

    log "PR comment written: $COMMENT_FILE"
}

post_comment_if_requested() {
    if [[ "$POST_COMMENT" != true ]]; then
        return
    fi

    gh pr comment "$PR_NUMBER" --body-file "$COMMENT_FILE"
    log "Posted smoke evidence comment to PR #$PR_NUMBER."
}

main() {
    parse_args "$@"
    prepare_run_dir
    source_env_if_available
    if [[ "$USE_EXISTING" == true ]]; then
        adopt_existing_app
    else
        launch_app
        discover_socket
    fi
    probe_healthz

    if [[ "$DETERMINISTIC_SIGNAL" == true ]]; then
        capture_step "01-app-launched" "Debug app is visible; hook listener health check passed."
        run_deterministic_signal
    elif [[ "$NON_INTERACTIVE" == true ]]; then
        capture_step "01-app-launched" "Debug app launched; hook listener health check passed."
    else
        run_interactive_steps
    fi

    write_comment_file
    post_comment_if_requested

    log "Claude integration smoke complete."
    log "Artifacts: $RUN_DIR"
    log "Evidence list: $URL_FILE"
}

main "$@"
