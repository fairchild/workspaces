#!/usr/bin/env bash
# ==========================================================================
# claude-integration-smoke.sh - Interactive evidence harness for Claude Code
# ==========================================================================
#
# This harness automates the repeatable parts of the five-channel integration
# smoke and prompts for the parts that must be human-driven in a real terminal:
# accepting the Settings merge, driving a real Claude permission prompt, and
# opening the conversation log / headless quick action surfaces.
#
# Usage:
#   ./scripts/claude-integration-smoke.sh --pr 455 --no-build
#   ./scripts/claude-integration-smoke.sh --pr 455 --no-build --fixture-home
#   ./scripts/claude-integration-smoke.sh --non-interactive --no-build
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
POST_COMMENT=false
WINDOW_TIMEOUT_SECONDS=15
ENV_FILE=""
APP_LOG=""
APP_PID=""
SOCKET_PATH=""
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

discover_socket() {
    local deadline=$((SECONDS + 10))
    local socket=""

    while (( SECONDS < deadline )); do
        socket="$(
            sed -nE 's/.*listener started at (.*hooks-[0-9]+\.sock).*/\1/p' "$APP_LOG" | tail -n 1
        )"
        if [[ -n "$socket" && -S "$socket" ]]; then
            SOCKET_PATH="$socket"
            log "Hook socket: $SOCKET_PATH"
            return
        fi
        sleep 1
    done

    fail "Could not find live hooks-<pid>.sock in $APP_LOG"
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
    if ! (
        cd "$REPO_ROOT"
        ./scripts/capture-window.sh --output "$screenshot"
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

    if wait_for_user "Optional: invoke a Claude headless quick action or run the headless service flow and capture its progress."; then
        capture_step "09-headless-quick-action" "Headless Claude run reports separately from the interactive terminal session."
    fi
}

write_comment_file() {
    local date_string
    date_string="$(date '+%Y-%m-%d')"
    cat >"$COMMENT_FILE" <<EOF
## Manual Claude integration smoke evidence

Captured against the integrated five-channel Claude Code architecture on ${date_string}.

$(cat "$URL_FILE")

Behaviors covered:
- Debug app launches and the pid-scoped hook listener answers \`/healthz\`.
- Settings -> Agents renders the merge preview and installs with backup visibility.
- A real Claude terminal session can drive awaiting-input and completion UI states.
- OSC fallback can update host state when no matching hook event arrives.
- Conversation log and headless run surfaces are exercised when captured above.

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
    launch_app
    discover_socket
    probe_healthz

    if [[ "$NON_INTERACTIVE" == true ]]; then
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
