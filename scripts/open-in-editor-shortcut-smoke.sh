#!/bin/bash
# ==========================================================================
# open-in-editor-shortcut-smoke.sh - End-to-end Cmd+Shift+O regression smoke
# ==========================================================================
#
# Verifies both Open in Editor shortcut paths:
# 1) repo selected + no file preview -> project root only
# 2) file preview selected -> project root + file path
#
# It launches the debug binary via launch-dev, injects a fake Zed CLI shim,
# sends Cmd+Shift+O, then validates captured launch arguments.
#
# ==========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LAUNCH_SCRIPT="$REPO_ROOT/scripts/launch-dev.sh"
APP_NAME="WorkspaceManager"
INSTALLED_APP_BINARY="/Applications/$APP_NAME.app/Contents/MacOS/$APP_NAME"

BUILD_BEFORE_LAUNCH=false
KEEP_TMP=false
APP_PID=""
APP_LOG=""
ARG_LINES=()
ACCOUNT_HOME=""

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wm-open-shortcut-smoke-XXXXXX")"
TEST_HOME="$TMP_ROOT/home"
CAPTURE_DIR="$TMP_ROOT/captures"
FAKE_ZED_APP="$TMP_ROOT/Zed.app"
FAKE_ZED_CLI="$FAKE_ZED_APP/Contents/MacOS/cli"

resolve_account_home() {
    local directory_home=""
    if command -v dscl >/dev/null 2>&1; then
        directory_home="$(dscl . -read "/Users/$USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
    fi

    if [[ -z "$directory_home" ]]; then
        directory_home="$(eval echo "~$USER")"
    fi

    if [[ -z "$directory_home" ]]; then
        fail "unable to resolve account home directory"
    fi

    ACCOUNT_HOME="$directory_home"
}

log() {
    echo "[$(date +%H:%M:%S)] $*"
}

fail() {
    echo "ERROR: $*" >&2
    if [[ -n "$APP_LOG" && -f "$APP_LOG" ]]; then
        echo "--- app log tail ($APP_LOG) ---" >&2
        tail -n 80 "$APP_LOG" >&2 || true
    fi
    exit 1
}

usage() {
    cat <<'USAGE'
Usage: ./scripts/open-in-editor-shortcut-smoke.sh [options]

Options:
  --build              Build before launch (default: reuse existing debug binary)
  --keep-tmp           Keep temp artifacts for debugging
  --help, -h           Show this help

Notes:
- Requires Automation/Accessibility permissions to send Cmd+Shift+O via System Events.
- Fails if any WorkspaceManager process is already running.
USAGE
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --build)
                BUILD_BEFORE_LAUNCH=true
                shift
                ;;
            --keep-tmp)
                KEEP_TMP=true
                shift
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
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

stop_app() {
    if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" >/dev/null 2>&1; then
        kill "$APP_PID" >/dev/null 2>&1 || true
        wait "$APP_PID" >/dev/null 2>&1 || true
    fi
    APP_PID=""
    APP_LOG=""
}

cleanup() {
    stop_app
    if [[ "$KEEP_TMP" == true ]]; then
        log "Preserved temp artifacts at: $TMP_ROOT"
    else
        rm -rf "$TMP_ROOT"
    fi
}

ensure_clean_process_space() {
    if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
        fail "$APP_NAME is already running; quit it before running this smoke test"
    fi

    if pgrep -f "$INSTALLED_APP_BINARY" >/dev/null 2>&1; then
        fail "Installed app is running at $INSTALLED_APP_BINARY; quit it before running this smoke test"
    fi
}

prepare_fixture_home() {
    mkdir -p \
        "$TEST_HOME/code/skills" \
        "$TEST_HOME/code/services" \
        "$TEST_HOME/code/superpowers" \
        "$TEST_HOME/code/workspaces"

    printf '# fixture\n' >"$TEST_HOME/code/skills/README.md"
}

prepare_fake_zed_cli() {
    mkdir -p "$(dirname "$FAKE_ZED_CLI")"
    cat >"$FAKE_ZED_CLI" <<'SH'
#!/bin/bash
set -euo pipefail

capture_dir="${WORKSPACES_EDITOR_TEST_CAPTURE_DIR:?}"
mkdir -p "$capture_dir"

counter_file="$capture_dir/counter"
count=0
if [[ -f "$counter_file" ]]; then
    count="$(cat "$counter_file")"
fi
count=$((count + 1))
printf '%s\n' "$count" >"$counter_file"

args_file="$capture_dir/invocation-${count}.args"
: >"$args_file"
for arg in "$@"; do
    printf '%s\n' "$arg" >>"$args_file"
done
SH
    chmod +x "$FAKE_ZED_CLI"
}

reset_capture_dir() {
    rm -rf "$CAPTURE_DIR"
    mkdir -p "$CAPTURE_DIR"
}

launch_app() {
    local scenario="$1"
    shift
    local data_dir="$TMP_ROOT/data-$scenario"
    mkdir -p "$data_dir"

    local -a launch_args=(--no-kill --no-activate --data-dir "$data_dir")
    if [[ "$BUILD_BEFORE_LAUNCH" != true ]]; then
        launch_args=(--no-build "${launch_args[@]}")
    fi

    local launch_output
    launch_output="$(
        cd "$REPO_ROOT"
        env \
            HOME="$TEST_HOME" \
            WORKSPACES_EDITOR_ZED_APP_PATH="$FAKE_ZED_APP" \
            WORKSPACES_EDITOR_TEST_CAPTURE_DIR="$CAPTURE_DIR" \
            "$@" \
            "$LAUNCH_SCRIPT" "${launch_args[@]}"
    )" || fail "failed to launch debug app for scenario '$scenario'"

    printf '%s\n' "$launch_output"

    APP_PID="$(printf '%s\n' "$launch_output" | sed -n 's/.*WorkspaceManager running (pid=\([0-9][0-9]*\)).*/\1/p' | tail -n 1)"
    APP_LOG="$(printf '%s\n' "$launch_output" | sed -n 's/.*Log file: \(.*\)$/\1/p' | tail -n 1)"

    [[ -n "$APP_PID" ]] || fail "could not parse app pid from launch output"
    [[ -n "$APP_LOG" ]] || fail "could not parse app log path from launch output"
}

activate_app() {
    osascript -e 'tell application "System Events" to set frontmost of process "WorkspaceManager" to true' >/dev/null 2>&1 \
        || fail "could not activate WorkspaceManager"
    sleep 0.4
}

send_open_shortcut() {
    osascript -e 'tell application "System Events" to keystroke "o" using {command down, shift down}' >/dev/null 2>&1 \
        || fail "failed sending Cmd+Shift+O"
}

wait_for_log_pattern() {
    local pattern="$1"
    local timeout_seconds="${2:-8}"
    local deadline=$((SECONDS + timeout_seconds))

    while ((SECONDS < deadline)); do
        if [[ -f "$APP_LOG" ]] && rg -q "$pattern" "$APP_LOG"; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

wait_for_metric_success() {
    local target_kind="$1"
    local timeout_seconds="${2:-8}"
    local pattern="\\[Perf\\] metric=open_in_editor_launch .*target=${target_kind} .*outcome=success"
    wait_for_log_pattern "$pattern" "$timeout_seconds"
}

wait_for_invocation() {
    local timeout_seconds="${1:-6}"
    local deadline=$((SECONDS + timeout_seconds))

    while ((SECONDS < deadline)); do
        if [[ -f "$CAPTURE_DIR/invocation-1.args" ]]; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

trigger_shortcut_until_invoked() {
    local attempts=6
    local i
    for ((i = 1; i <= attempts; i++)); do
        send_open_shortcut
        if wait_for_invocation 1; then
            return 0
        fi
        sleep 0.25
    done
    return 1
}

verify_single_invocation() {
    local invocation_count
    invocation_count="$(find "$CAPTURE_DIR" -maxdepth 1 -name 'invocation-*.args' | wc -l | tr -d ' ')"
    [[ "$invocation_count" == "1" ]] || fail "expected exactly 1 editor launch invocation, found $invocation_count"
}

read_args_file() {
    local file_path="$1"
    ARG_LINES=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        ARG_LINES+=("$line")
    done < "$file_path"
}

verify_repo_only_invocation() {
    verify_single_invocation

    read_args_file "$CAPTURE_DIR/invocation-1.args"
    [[ "${#ARG_LINES[@]}" -eq 1 ]] || fail "repo-only scenario expected 1 argument, found ${#ARG_LINES[@]}"

    case "${ARG_LINES[0]}" in
        "$TEST_HOME/code/skills"|"$TEST_HOME/code/services"|"$TEST_HOME/code/superpowers"|"$TEST_HOME/code/workspaces")
            ;;
        *)
            fail "repo-only scenario used unexpected project root: ${ARG_LINES[0]}"
            ;;
    esac
}

verify_file_selected_invocation() {
    verify_single_invocation

    read_args_file "$CAPTURE_DIR/invocation-1.args"
    [[ "${#ARG_LINES[@]}" -eq 2 ]] || fail "file-selected scenario expected 2 arguments, found ${#ARG_LINES[@]}"

    local expected_root="$TEST_HOME/code/skills"
    local expected_file="$TEST_HOME/code/skills/README.md"

    [[ "${ARG_LINES[0]}" == "$expected_root" ]] || fail "file-selected scenario root mismatch: ${ARG_LINES[0]}"
    [[ "${ARG_LINES[1]}" == "$expected_file" ]] || fail "file-selected scenario file mismatch: ${ARG_LINES[1]}"
}

run_repo_only_scenario() {
    log "Scenario 1/2: repo selected + no file preview"
    reset_capture_dir

    launch_app "repo-only" \
        WORKSPACES_UI_FIXTURE=1 \
        WORKSPACES_PERF_AUTO_SELECT_FIRST_REPO=1

    sleep 1.2
    activate_app
    trigger_shortcut_until_invoked || fail "repo-only scenario did not trigger editor launch"
    verify_repo_only_invocation
    wait_for_metric_success "project" 8 \
        || fail "repo-only scenario missing open_in_editor_launch success metric in $APP_LOG"
    stop_app
}

run_file_selected_scenario() {
    log "Scenario 2/2: file selected in preview"
    reset_capture_dir

    launch_app "file-selected" \
        WORKSPACES_UI_FIXTURE=1 \
        WORKSPACES_UI_FIXTURE_OPEN_PREVIEW=1 \
        WORKSPACES_UI_FIXTURE_PREVIEW_REPO=skills \
        WORKSPACES_UI_FIXTURE_PREVIEW_PATH=README.md

    wait_for_log_pattern '\[UIFixture\] Preview bootstrap applied' 10 \
        || fail "file-selected scenario never reached preview bootstrap"

    activate_app
    trigger_shortcut_until_invoked || fail "file-selected scenario did not trigger editor launch"
    verify_file_selected_invocation
    wait_for_metric_success "project_and_file" 8 \
        || fail "file-selected scenario missing open_in_editor_launch success metric in $APP_LOG"
    stop_app
}

main() {
    parse_args "$@"
    trap cleanup EXIT

    require_cmd osascript
    require_cmd rg
    require_cmd sed
    require_cmd swift

    resolve_account_home
    ensure_clean_process_space
    prepare_fixture_home
    prepare_fake_zed_cli

    run_repo_only_scenario
    run_file_selected_scenario

    log "Open-in-editor shortcut smoke passed"
}

main "$@"
