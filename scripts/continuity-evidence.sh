#!/usr/bin/env bash
# continuity-evidence.sh — evidence that desktop terminal continuity holds across an app
# terminate/relaunch, and, with --kill-holder or --drill, what restore does when the tmux
# server holding the agents dies. Destructive steps run only on an isolated tmux socket
# named by --socket-label, with HOME, XDG_CONFIG_HOME, preferences and the Claude home inside
# the run directory, so the desktop's live `-L workspaces` sessions are never addressed.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/build-products.sh
source "$SCRIPT_DIR/lib/build-products.sh"

LAUNCH_SCRIPT="$REPO_ROOT/scripts/launch-dev.sh"
CAPTURE_SCRIPT="$REPO_ROOT/scripts/capture-window.sh"
PROBE_SCRIPT="$REPO_ROOT/scripts/tmux-continuity-probe.sh"
STUB_AGENT="$REPO_ROOT/scripts/lib/stub-agent.sh"
DRILL_SHELL_RC="$REPO_ROOT/scripts/lib/drill-shell.zsh"
EVENT_FORWARDER="$REPO_ROOT/Sources/WorkspaceManager/Resources/HookForwarders/event-forwarder.sh"
PREF_DOMAIN="com.cloudcompute.workspaces"
LIVE_SOCKET_LABEL="workspaces"
QUARANTINE_SOCKET_LABEL="workspaces-rejected-label"
PREFS_SUITE_PREFIX="com.cloudcompute.workspaces.drill"
ALL_PASSES=(tmux-on-app tmux-off-app tmux-on-server tmux-off-server ghostty-on ghostty-off)
DRILL_TILES=("ws_launch|high|done" "hand_typed|medium|done" "split|low|done" "mid_turn|xhigh|held")

TARGET_PATH="$HOME/code/workspaces"
TARGET_GIVEN=false
LABEL="app-restart"
RUN_ROOT="$REPO_ROOT/output/continuity-evidence"
RUN_DIR=""
WINDOW_TIMEOUT_SECONDS=15
NO_BUILD=false
TRUST_MISE=false
SOCKET_LABEL=""
SOCKET_LABEL_GIVEN=false
KILL_HOLDER=false
KILL_ORDER="app-first"
KILL_ORDER_GIVEN=false
DRILL=false
SETTLE_SECONDS=30
TILE_TIMEOUT_SECONDS=60
SELECTED_PASSES=()

TARGET_REAL_PATH=""
DATA_DIR=""
SUMMARY_PATH=""
ROWS_PATH=""
SUMMARY_WRITTEN=false
FAILURE_REASON=""
TMUX_LABEL="$LIVE_SOCKET_LABEL"
ISOLATED=false
ISOLATION_ENV=()
USED_LABELS=()
USED_SUITES=()
SOCKET_DIRS=()
WS_CLI=""

PASS_ID=""
PASS_DIR=""
PASS_MODE=""
PASS_FLAG=""
PASS_KILL_ORDER=""
ISOLATED_HOME=""
DRILL_REPO=""
APP_PID=""
APP_WINDOW_ID=""
APP_LOG=""
REPO_ID=""

BEFORE_PID=""
BEFORE_WINDOW_ID=""
BEFORE_LOG=""
BEFORE_CAPTURED_AT=""
BEFORE_TMUX_SESSION=""
AFTER_PID=""
AFTER_WINDOW_ID=""
AFTER_LOG=""
AFTER_CAPTURED_AT=""
RESTORE_ELAPSED_SECONDS=""
CLOSE_PROOF_TXT=""
PROBE_START_LOG=""
PROBE_CHECK_LOG=""
PROBE_CLEANUP_LOG=""
PROBE_USED=false
KILLED_SERVER_PID=""

PREF_LAST_SURFACE_HAD=false
PREF_LAST_SURFACE_VALUE=""
PREF_CONTINUITY_MANIFEST_HAD=false
PREF_CONTINUITY_MANIFEST_VALUE=""

main() {
    parse_args "$@"
    validate_mode
    ensure_dependencies
    prepare_paths
    trap cleanup EXIT
    trap 'note_failed_command "$LINENO" "$BASH_COMMAND"' ERR
    if [[ "$DRILL" == true ]]; then
        run_drill
    else
        run_lane
    fi
}

usage() {
    cat <<'USAGE'
Usage: ./scripts/continuity-evidence.sh [options]

Options:
  --target <path>          Local repo/workspace path to validate (default: ~/code/workspaces).
                           Only for runs on the live socket; isolated runs use a scratch repo.
  --label <label>          Label for tmux continuity probe artifacts (default: app-restart)
  --output-dir <path>      Artifact directory (default: output/continuity-evidence/<timestamp>)
  --no-build               Reuse the current debug binary
  --trust-mise             Trust this repo's .mise.toml before launch
  --window-timeout <s>     Visible-window timeout passed to launch-dev.sh (default: 15)
  --socket-label <label>   Run against an isolated tmux socket (-L <label>) with HOME,
                           XDG_CONFIG_HOME, preferences suite and Claude home in the run
                           directory. Required by --kill-holder and --drill. Refuses
                           "workspaces", "workspaces-rejected-label", anything the app would
                           quarantine, and a label whose server is already running.
  --kill-holder            Instead of a plain terminate, kill the holder: terminate the app by
                           pid, kill the isolated tmux server by the pid it reports, relaunch,
                           and record what restore did.
  --kill-order <order>     app-first (default) or server-first: kill the server while the app
                           still runs, then terminate the app.
  --drill                  Run the holder-death matrix (implies --kill-holder). Each pass gets
                           its own socket <label>-pN, HOME, data dir and preferences suite.
  --pass <id>              Limit --drill to one pass (repeatable): tmux-on-app, tmux-off-app,
                           tmux-on-server, tmux-off-server, ghostty-on, ghostty-off
  --settle <s>             Seconds to wait for restore after relaunch in --drill (default: 30)
  --help, -h               Show this help

What the default run proves:
  - debug app opens a local repo terminal in tmux_per_session mode
  - the exact app pid exits after normal termination
  - relaunch restores the same terminal surface from persisted continuity state
  - the tmux socket survives the app terminate/relaunch boundary

What --drill records (summary.json, one row per tile and pass):
  tiles from `ws launch`, a hand-typed `claude`, a split, one agent mid-turn, and the
  cmd+t tab and mixed-window cases (recorded as not_drivable); the rung each tile was
  expected to take after holder death, the rung it took, and the prefill text. Agents are
  scripts/lib/stub-agent.sh on PATH as `claude`: deterministic and token-free.

The script writes an evidence bundle under output/continuity-evidence/ and does
not upload artifacts. Upload screenshots with scripts/evidence.sh; summary.json and
the close proof go up as text.
USAGE
}

log() {
    echo "[$(date +%H:%M:%S)] $*"
}

fail() {
    FAILURE_REASON="$*"
    echo "ERROR: $*" >&2
    exit 1
}

note_failed_command() {
    [[ -n "$FAILURE_REASON" ]] || FAILURE_REASON="line $1: '$2' failed${PASS_ID:+ in pass $PASS_ID}"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target)
                [[ $# -ge 2 ]] || fail "--target requires a value"
                TARGET_PATH="$2"
                TARGET_GIVEN=true
                shift 2
                ;;
            --label)
                [[ $# -ge 2 ]] || fail "--label requires a value"
                LABEL="$2"
                shift 2
                ;;
            --output-dir)
                [[ $# -ge 2 ]] || fail "--output-dir requires a value"
                RUN_DIR="$2"
                shift 2
                ;;
            --no-build)
                NO_BUILD=true
                shift
                ;;
            --trust-mise)
                TRUST_MISE=true
                shift
                ;;
            --window-timeout)
                [[ $# -ge 2 ]] || fail "--window-timeout requires a value"
                [[ "$2" =~ ^[0-9]+$ ]] || fail "--window-timeout must be an integer"
                WINDOW_TIMEOUT_SECONDS="$2"
                shift 2
                ;;
            --socket-label)
                [[ $# -ge 2 ]] || fail "--socket-label requires a value"
                SOCKET_LABEL="$2"
                SOCKET_LABEL_GIVEN=true
                shift 2
                ;;
            --kill-holder)
                KILL_HOLDER=true
                shift
                ;;
            --kill-order)
                [[ $# -ge 2 ]] || fail "--kill-order requires a value"
                KILL_ORDER="$2"
                KILL_ORDER_GIVEN=true
                shift 2
                ;;
            --drill)
                DRILL=true
                KILL_HOLDER=true
                shift
                ;;
            --pass)
                [[ $# -ge 2 ]] || fail "--pass requires a value"
                SELECTED_PASSES+=("$2")
                shift 2
                ;;
            --settle)
                [[ $# -ge 2 ]] || fail "--settle requires a value"
                [[ "$2" =~ ^[0-9]+$ ]] || fail "--settle must be an integer"
                SETTLE_SECONDS="$2"
                shift 2
                ;;
            --help | -h)
                usage
                exit 0
                ;;
            *)
                fail "Unknown argument: $1"
                ;;
        esac
    done
}

validate_mode() {
    if [[ "$KILL_HOLDER" == true && -z "$SOCKET_LABEL" ]]; then
        fail "--kill-holder and --drill kill a tmux server and need an isolated one: pass --socket-label <label>"
    fi
    case "$KILL_ORDER" in
        app-first | server-first) ;;
        *) fail "--kill-order must be app-first or server-first (got '$KILL_ORDER')" ;;
    esac
    [[ "$KILL_ORDER_GIVEN" == false || "$KILL_HOLDER" == true ]] || fail "--kill-order only applies with --kill-holder"
    [[ "$KILL_ORDER_GIVEN" == false || "$DRILL" == false ]] || fail "--drill runs both kill orders; choose passes with --pass"
    [[ ${#SELECTED_PASSES[@]} -eq 0 || "$DRILL" == true ]] || fail "--pass only applies with --drill"
    local pass
    for pass in ${SELECTED_PASSES[@]+"${SELECTED_PASSES[@]}"}; do
        pass_index "$pass" >/dev/null || fail "unknown pass '$pass' (expected one of: ${ALL_PASSES[*]})"
    done
    [[ "$SOCKET_LABEL_GIVEN" == true ]] || return 0
    refuse_unsafe_label "$SOCKET_LABEL"
    [[ "$DRILL" == false || ${#SOCKET_LABEL} -le 60 ]] || fail "--socket-label must be 60 characters or fewer with --drill (passes append -pN)"
    [[ "$TARGET_GIVEN" == false ]] || fail "--target applies only to runs on the live socket; isolated runs create their own scratch repo"
    ISOLATED=true
    TMUX_LABEL="$SOCKET_LABEL"
}

refuse_unsafe_label() {
    local label="$1"
    [[ "$label" != "$LIVE_SOCKET_LABEL" ]] || fail "refusing socket label '$label': it is the desktop's live tmux socket"
    [[ "$label" != "$QUARANTINE_SOCKET_LABEL" ]] || fail "refusing socket label '$label': the app quarantines rejected labels there"
    [[ ${#label} -ge 1 && ${#label} -le 64 ]] || fail "refusing socket label '$label': it must be 1-64 characters"
    [[ "$label" =~ ^[A-Za-z0-9._-]+$ ]] || fail "refusing socket label '$label': only ASCII letters, digits, '-', '_' and '.' are allowed (TmuxSessionProbe.isSafeSocketLabel)"
}

pass_index() {
    local wanted="$1" index=1 pass
    for pass in "${ALL_PASSES[@]}"; do
        if [[ "$pass" == "$wanted" ]]; then
            echo "$index"
            return 0
        fi
        index=$((index + 1))
    done
    return 1
}

ensure_dependencies() {
    command -v swift >/dev/null 2>&1 || fail "swift is required"
    command -v screencapture >/dev/null 2>&1 || fail "screencapture is required"
    command -v tmux >/dev/null 2>&1 || fail "tmux is required"
    command -v jq >/dev/null 2>&1 || fail "jq is required"
    [[ -x "$LAUNCH_SCRIPT" ]] || fail "missing launch script: $LAUNCH_SCRIPT"
    [[ -x "$CAPTURE_SCRIPT" ]] || fail "missing capture script: $CAPTURE_SCRIPT"
    [[ -x "$PROBE_SCRIPT" ]] || fail "missing tmux probe script: $PROBE_SCRIPT"
    [[ "$ISOLATED" == false ]] || command -v git >/dev/null 2>&1 || fail "git is required for the scratch repo"
    [[ "$DRILL" == false ]] || command -v sqlite3 >/dev/null 2>&1 || fail "sqlite3 is required for --drill"
    [[ "$DRILL" == false ]] || [[ -x "$STUB_AGENT" && -f "$DRILL_SHELL_RC" && -f "$EVENT_FORWARDER" ]] \
        || fail "--drill needs $STUB_AGENT, $DRILL_SHELL_RC and $EVENT_FORWARDER"
}

prepare_paths() {
    if [[ -z "$RUN_DIR" ]]; then
        RUN_DIR="$RUN_ROOT/$(date +%Y%m%d-%H%M%S)"
    else
        RUN_DIR="$(expand_path "$RUN_DIR")"
    fi
    mkdir -p "$RUN_DIR"
    RUN_DIR="$(cd "$RUN_DIR" && pwd -P)"
    DATA_DIR="$RUN_DIR/data"
    SUMMARY_PATH="$RUN_DIR/summary.json"
    ROWS_PATH="$RUN_DIR/rows.jsonl"
    CLOSE_PROOF_TXT="$RUN_DIR/closed-process-proof.txt"
    PROBE_START_LOG="$RUN_DIR/tmux-probe-start.log"
    PROBE_CHECK_LOG="$RUN_DIR/tmux-probe-check.log"
    PROBE_CLEANUP_LOG="$RUN_DIR/tmux-probe-cleanup.log"
    [[ "$ISOLATED" == true ]] && return 0
    TARGET_PATH="$(expand_path "$TARGET_PATH")"
    [[ -d "$TARGET_PATH" ]] || fail "target path is not a directory: $TARGET_PATH"
    TARGET_REAL_PATH="$(cd "$TARGET_PATH" && pwd -P)"
}

expand_path() {
    local path="$1"
    if [[ "$path" == "~" ]]; then
        printf "%s\n" "$HOME"
    elif [[ "$path" == "~/"* ]]; then
        printf "%s\n" "$HOME/${path#~/}"
    else
        printf "%s\n" "$path"
    fi
}

run_lane() {
    prepare_lane_state
    run_probe_start

    local before_launch_out="$RUN_DIR/launch-before.log"
    log "Launching before-close app state on socket -L $TMUX_LABEL..."
    launch_lane_app "$before_launch_out" true true
    BEFORE_PID="$(parse_launch_pid "$before_launch_out")"
    BEFORE_WINDOW_ID="$(parse_launch_window_id "$before_launch_out")"
    BEFORE_LOG="$(parse_launch_log_path "$before_launch_out")"
    APP_PID="$BEFORE_PID"
    [[ -n "$BEFORE_PID" && -n "$BEFORE_WINDOW_ID" && -n "$BEFORE_LOG" ]] \
        || fail "could not parse before launch pid/window/log"

    wait_for_log_pattern "$BEFORE_LOG" 'TerminalContinuity.*mode=tmux_per_session' 20 \
        || fail "before launch did not persist terminal continuity in tmux mode"
    BEFORE_TMUX_SESSION="$(parse_tmux_session_from_log "$BEFORE_LOG")"
    [[ -n "$BEFORE_TMUX_SESSION" ]] || fail "could not parse tmux session from before launch log"
    tmux -L "$TMUX_LABEL" has-session -t "$BEFORE_TMUX_SESSION" \
        >"$RUN_DIR/app-tmux-session-before.log" 2>&1 \
        || fail "app tmux session was not present: $BEFORE_TMUX_SESSION"

    capture_window "$BEFORE_PID" "$BEFORE_WINDOW_ID" "$RUN_DIR/before-close.png"
    BEFORE_CAPTURED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    if [[ "$KILL_HOLDER" == true ]]; then
        kill_holder "$KILL_ORDER" "$TMUX_LABEL" "$RUN_DIR"
    else
        log "Terminating before-close app pid=$BEFORE_PID..."
        terminate_app_pid "$BEFORE_PID"
        wait_for_pid_exit "$BEFORE_PID" || fail "before app pid did not exit: $BEFORE_PID"
    fi
    write_close_proof
    run_probe_check

    local after_launch_out="$RUN_DIR/launch-after.log"
    local restore_started_at restore_finished_at
    restore_started_at="$(date +%s)"
    log "Relaunching without auto-selection..."
    launch_lane_app "$after_launch_out" false false
    restore_finished_at="$(date +%s)"
    RESTORE_ELAPSED_SECONDS="$((restore_finished_at - restore_started_at))"

    AFTER_PID="$(parse_launch_pid "$after_launch_out")"
    AFTER_WINDOW_ID="$(parse_launch_window_id "$after_launch_out")"
    AFTER_LOG="$(parse_launch_log_path "$after_launch_out")"
    APP_PID="$AFTER_PID"
    [[ -n "$AFTER_PID" && -n "$AFTER_WINDOW_ID" && -n "$AFTER_LOG" ]] \
        || fail "could not parse after launch pid/window/log"

    wait_for_log_pattern "$AFTER_LOG" 'TerminalContinuity.*mode=tmux_per_session' 20 \
        || fail "after launch did not restore and persist terminal continuity in tmux mode"
    if [[ "$KILL_HOLDER" == true ]]; then
        record_restore_outcome "$RUN_DIR" "$AFTER_LOG"
    else
        tmux -L "$TMUX_LABEL" has-session -t "$BEFORE_TMUX_SESSION" \
            >"$RUN_DIR/app-tmux-session-after.log" 2>&1 \
            || fail "app tmux session was not present after relaunch: $BEFORE_TMUX_SESSION"
    fi

    capture_window "$AFTER_PID" "$AFTER_WINDOW_ID" "$RUN_DIR/after-reopen.png"
    AFTER_CAPTURED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    SUMMARY_WRITTEN=true
    write_lane_summary "passed" ""

    log "Continuity evidence passed."
    log "Run directory: $RUN_DIR"
    log "Before screenshot: $RUN_DIR/before-close.png"
    log "Closed proof: $CLOSE_PROOF_TXT"
    log "After screenshot: $RUN_DIR/after-reopen.png"
    log "Summary: $SUMMARY_PATH"
}

prepare_lane_state() {
    if [[ "$ISOLATED" == false ]]; then
        preserve_preferences
        set_continuity_preferences
        return 0
    fi
    PASS_DIR="$RUN_DIR"
    prepare_isolated_home "$SOCKET_LABEL" tmux_per_session off
    TARGET_REAL_PATH="$DRILL_REPO"
}

read_pref() {
    local key="$1"
    defaults read "$PREF_DOMAIN" "$key" 2>/dev/null
}

preserve_preferences() {
    local value
    if value="$(read_pref mainWindow.lastSurface)"; then
        PREF_LAST_SURFACE_HAD=true
        PREF_LAST_SURFACE_VALUE="$value"
    fi
    if value="$(read_pref terminalContinuity.manifest.v1)"; then
        PREF_CONTINUITY_MANIFEST_HAD=true
        PREF_CONTINUITY_MANIFEST_VALUE="$value"
    fi
}

set_continuity_preferences() {
    log "Using terminal mode override: tmux_per_session"
    defaults delete "$PREF_DOMAIN" mainWindow.lastSurface >/dev/null 2>&1 || true
    defaults delete "$PREF_DOMAIN" terminalContinuity.manifest.v1 >/dev/null 2>&1 || true
}

prepare_isolated_home() {
    local label="$1"
    local mode="$2"
    local flag="$3"
    refuse_unsafe_label "$label"
    refuse_running_server "$label"
    TMUX_LABEL="$label"
    USED_LABELS+=("$label")
    ISOLATED_HOME="$PASS_DIR/home"
    DATA_DIR="$PASS_DIR/data"
    mkdir -p "$ISOLATED_HOME/code" "$ISOLATED_HOME/.claude" "$ISOLATED_HOME/.drill/bin" \
        "$ISOLATED_HOME/.drill/autorun" "$ISOLATED_HOME/.drill/observe" \
        "$PASS_DIR/xdg" "$PASS_DIR/synthetic" "$DATA_DIR"
    touch "$ISOLATED_HOME/.claude/.stub-agent-sandbox"
    ln -sf "$STUB_AGENT" "$ISOLATED_HOME/.drill/bin/claude"
    cp "$DRILL_SHELL_RC" "$ISOLATED_HOME/.zshrc"
    write_isolated_claude_settings "$ISOLATED_HOME/.claude/settings.json"
    create_scratch_repo "$ISOLATED_HOME/code/drill-repo"
    build_isolation_env "$label" "$mode" "$flag"
}

refuse_running_server() {
    local label="$1"
    if tmux -L "$label" list-sessions >/dev/null 2>&1; then
        fail "a tmux server is already running on -L $label; pick a fresh --socket-label so this run never kills a server it did not start"
    fi
}

write_isolated_claude_settings() {
    [[ "$EVENT_FORWARDER" != *"'"* ]] || fail "the hook forwarder path contains a single quote: $EVENT_FORWARDER"
    jq -n --arg command "'$EVENT_FORWARDER'" '
        [{hooks: [{type: "command", command: $command}]}] as $hook
        | {hooks: {SessionStart: $hook, UserPromptSubmit: $hook, Stop: $hook}}' >"$1"
}

create_scratch_repo() {
    local repo="$1"
    mkdir -p "$repo"
    printf 'continuity drill scratch repo\n' >"$repo/README.md"
    scratch_git "$repo" init -q -b main
    scratch_git "$repo" add README.md
    scratch_git "$repo" commit -q --no-verify -m "drill: scratch repo"
    DRILL_REPO="$(cd "$repo" && pwd -P)"
}

scratch_git() {
    local repo="$1"
    shift
    env HOME="$ISOLATED_HOME" GIT_CONFIG_NOSYSTEM=1 git -C "$repo" \
        -c user.name=continuity-drill -c user.email=drill@localhost -c commit.gpgsign=false "$@"
}

build_isolation_env() {
    local label="$1"
    local mode="$2"
    local flag="$3"
    local suite="$PREFS_SUITE_PREFIX.$label"
    local socket_dir
    socket_dir="$(mktemp -d "${TMPDIR:-/tmp}/wsdrill.XXXXXX")"
    SOCKET_DIRS+=("$socket_dir")
    USED_SUITES+=("$suite")
    ISOLATION_ENV=(
        "HOME=$ISOLATED_HOME"
        "CFFIXED_USER_HOME=$ISOLATED_HOME"
        "ZDOTDIR=$ISOLATED_HOME"
        "SHELL=/bin/zsh"
        "PATH=$ISOLATED_HOME/.drill/bin:$PATH"
        "XDG_CONFIG_HOME=$PASS_DIR/xdg"
        "CLAUDE_CONFIG_DIR=$ISOLATED_HOME/.claude"
        "WORKSPACES_TMUX_SOCKET_LABEL=$label"
        "WORKSPACES_SYNTHETIC_ROOT=$PASS_DIR/synthetic"
        "WORKSPACES_PREFERENCES_SUITE=$suite"
        "WORKSPACES_HOOKS_SOCKET_OVERRIDE=$socket_dir/hooks.sock"
        "WORKSPACES_HOOKS_SOCKET=$socket_dir/hooks.sock"
        "WORKSPACES_AUTOMATION_API=1"
        "WORKSPACES_AUTOMATION_OPERATOR=1"
        "WORKSPACES_TERMINAL_MULTIPLEXING_MODE=$mode"
    )
    if [[ "$flag" == on ]]; then
        ISOLATION_ENV+=("WORKSPACES_RESTORE_SESSIONS_ON_LAUNCH=1" "WORKSPACES_RESTORE_AUTORUN=1")
    fi
    printf '%s\n' "${ISOLATION_ENV[@]}" >"$PASS_DIR/isolation-env.txt"
}

run_probe_start() {
    [[ "$KILL_HOLDER" == false ]] || return 0
    PROBE_USED=true
    probe cleanup >"$PROBE_CLEANUP_LOG" 2>&1 || true
    probe start >"$PROBE_START_LOG" 2>&1
}

probe() {
    env -u TMUX -u TMUX_PANE ${ISOLATION_ENV[@]+"${ISOLATION_ENV[@]}"} \
        WORKSPACES_TMUX_SOCKET_LABEL="$TMUX_LABEL" "$PROBE_SCRIPT" "$1" "$TARGET_REAL_PATH" "$LABEL"
}

launch_lane_app() {
    local output_file="$1"
    local clean_flag="$2"
    local auto_select_flag="$3"
    local -a env_pairs=("WORKSPACES_TERMINAL_MULTIPLEXING_MODE=tmux_per_session")
    if [[ "$auto_select_flag" == true ]]; then
        env_pairs+=("WORKSPACES_PERF_AUTO_SELECT_FIRST_REPO=1" "WORKSPACES_PERF_AUTO_SELECT_REPO_PATH=$TARGET_REAL_PATH")
    fi
    launch_debug_app "$output_file" "$clean_flag" "$NO_BUILD" "${env_pairs[@]}"
}

launch_debug_app() {
    local output_file="$1"
    local clean_flag="$2"
    local skip_build="$3"
    shift 3
    local -a args=("--data-dir" "$DATA_DIR" "--window-timeout" "$WINDOW_TIMEOUT_SECONDS")
    local entry

    [[ "$skip_build" == true ]] && args+=("--no-build")
    [[ "$TRUST_MISE" == true ]] && args+=("--trust-mise")
    [[ "$clean_flag" == true ]] && args+=("--clean-data")
    [[ "$ISOLATED" == true ]] && args+=("--coexist" "--no-activate")
    for entry in ${ISOLATION_ENV[@]+"${ISOLATION_ENV[@]}"} "$@"; do
        args+=("--env" "$entry")
    done

    (
        cd "$REPO_ROOT"
        env -u TMUX -u TMUX_PANE "$LAUNCH_SCRIPT" "${args[@]}"
    ) | tee "$output_file"
}

parse_launch_pid() {
    sed -nE 's/.*WorkspaceManager running \(pid=([0-9]+)\).*/\1/p' "$1" | tail -n 1
}

parse_launch_window_id() {
    awk '/Verified visible window id:/ {print $NF}' "$1" | tail -n 1
}

parse_launch_log_path() {
    sed -nE 's/.*Log file: (.*)$/\1/p' "$1" | tail -n 1
}

wait_for_log_pattern() {
    local file="$1"
    local pattern="$2"
    local timeout_seconds="$3"
    local waited=0

    while ((waited < timeout_seconds)); do
        if [[ -f "$file" ]] && grep -E "$pattern" "$file" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done

    return 1
}

parse_tmux_session_from_log() {
    sed -nE 's/.*tmux_session=([^ ]+) mode=tmux_per_session.*/\1/p' "$1" | tail -n 1
}

capture_window() {
    local pid="$1"
    local window_id="$2"
    local output="$3"

    if [[ -n "$window_id" ]] && screencapture -x -l "$window_id" "$output"; then
        return 0
    fi

    "$CAPTURE_SCRIPT" --pid "$pid" --output "$output" >/dev/null
}

kill_holder() {
    local order="$1"
    local label="$2"
    local evidence_dir="$3"
    local server_pid
    server_pid="$(isolated_server_pid "$label")"
    log "Killing the holder ($order): app pid=$APP_PID, tmux -L $label server pid=${server_pid:-none}"
    if [[ "$order" == server-first && -n "$server_pid" ]]; then
        kill_isolated_server_pid "$label" "$server_pid"
        sleep 5
        [[ "$DRILL" == false ]] || snapshot_state holder-lost
    fi
    terminate_app_pid "$APP_PID" || true
    wait_for_pid_exit "$APP_PID" || kill -TERM "$APP_PID" 2>/dev/null || true
    wait_for_pid_exit "$APP_PID" || fail "app pid did not exit: $APP_PID"
    if [[ "$order" == app-first && -n "$server_pid" ]]; then
        kill_isolated_server_pid "$label" "$server_pid"
    fi
    if tmux -L "$label" list-sessions >/dev/null 2>&1; then
        fail "a tmux server still answers on -L $label after the holder kill"
    fi
    jq -n --arg order "$order" --arg label "$label" --arg app_pid "$APP_PID" --arg server_pid "$server_pid" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{order: $order, socket_label: $label, app_pid: $app_pid, server_pid: $server_pid, at: $at}' \
        >"$evidence_dir/holder-kill.json"
}

isolated_server_pid() {
    tmux -L "$1" display-message -p '#{pid}' 2>/dev/null || true
}

kill_isolated_server_pid() {
    local label="$1"
    local pid="$2"
    refuse_unsafe_label "$label"
    [[ "$pid" =~ ^[0-9]+$ ]] || fail "tmux -L $label reported a non-numeric server pid: '$pid'"
    server_pid_belongs_to_label "$pid" "$label" \
        || fail "pid $pid does not look like the tmux server for -L $label; not killing it"
    kill -TERM "$pid" 2>/dev/null || true
    wait_for_pid_exit "$pid" || kill -KILL "$pid" 2>/dev/null || true
    wait_for_pid_exit "$pid" || fail "tmux server pid $pid for -L $label did not exit"
    KILLED_SERVER_PID="$pid"
}

server_pid_belongs_to_label() {
    local command
    command="$(ps -p "$1" -o command= 2>/dev/null) "
    [[ "$command" == *tmux* && "$command" == *" -L $2 "* ]]
}

terminate_app_pid() {
    local pid="$1"
    TARGET_PID="$pid" swift - <<'SWIFT'
import AppKit
import Foundation

guard
    let rawPID = ProcessInfo.processInfo.environment["TARGET_PID"],
    let pid = Int32(rawPID)
else {
    exit(64)
}

guard let app = NSRunningApplication(processIdentifier: pid_t(pid)) else {
    exit(0)
}

exit(app.terminate() ? 0 : 1)
SWIFT
}

wait_for_pid_exit() {
    local pid="$1"
    local timeout_half_seconds=40
    local attempt

    for ((attempt = 0; attempt < timeout_half_seconds; attempt++)); do
        if ! kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        sleep 0.5
    done

    return 1
}

write_close_proof() {
    local window_count
    window_count="$(window_count_for_pid "$BEFORE_PID")"

    {
        echo "closed-check-date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "before-pid=$BEFORE_PID"
        echo "before-window-id=$BEFORE_WINDOW_ID"
        echo "remaining-window-count-for-pid=$window_count"
        [[ -z "$KILLED_SERVER_PID" ]] || echo "killed-tmux-server-pid=$KILLED_SERVER_PID socket=-L $TMUX_LABEL"
        if ps -p "$BEFORE_PID" -o pid=,command=; then
            echo "result=FAILED still running"
            return 1
        fi
        if [[ "$window_count" != "0" ]]; then
            echo "result=FAILED windows still visible for pid"
            return 1
        fi
        echo "result=PASS pid is no longer running after NSRunningApplication.terminate()"
    } >"$CLOSE_PROOF_TXT"
}

window_count_for_pid() {
    local pid="$1"
    WORKSPACES_CAPTURE_OWNER_PID="$pid" swift - <<'SWIFT'
import CoreGraphics
import Foundation

let targetPID = Int(ProcessInfo.processInfo.environment["WORKSPACES_CAPTURE_OWNER_PID"] ?? "") ?? -1
let ownerCandidates: Set<String> = ["WorkSpaces", "WorkspaceManager"]
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
var count = 0

for window in windows {
    let owner = window[kCGWindowOwnerName as String] as? String ?? ""
    let layer = window[kCGWindowLayer as String] as? Int ?? 1
    let ownerPID = window[kCGWindowOwnerPID as String] as? Int ?? -1
    if ownerCandidates.contains(owner), layer == 0, ownerPID == targetPID {
        count += 1
    }
}

print(count)
SWIFT
}

run_probe_check() {
    [[ "$PROBE_USED" == true ]] || return 0
    probe check >"$PROBE_CHECK_LOG" 2>&1
}

record_restore_outcome() {
    local evidence_dir="$1"
    local app_log="$2"
    sleep 5
    tmux -L "$TMUX_LABEL" list-sessions -F '#{session_id} #{session_name} #{session_created}' \
        >"$evidence_dir/tmux-sessions-after.txt" 2>&1 || true
    grep -iE 'restore|continuity|kill' "$app_log" >"$evidence_dir/restore-log.txt" 2>/dev/null || true
}

write_lane_summary() {
    jq -n \
        --arg status "$1" \
        --arg failure "$2" \
        --arg target_path "$TARGET_REAL_PATH" \
        --arg label "$LABEL" \
        --arg socket_label "$TMUX_LABEL" \
        --argjson isolated "$ISOLATED" \
        --argjson kill_holder "$KILL_HOLDER" \
        --arg kill_order "$KILL_ORDER" \
        --arg killed_server_pid "$KILLED_SERVER_PID" \
        --arg run_dir "$RUN_DIR" \
        --arg data_dir "$DATA_DIR" \
        --arg before_pid "$BEFORE_PID" \
        --arg before_window_id "$BEFORE_WINDOW_ID" \
        --arg before_captured_at "$BEFORE_CAPTURED_AT" \
        --arg before_log "$BEFORE_LOG" \
        --arg before_tmux_session "$BEFORE_TMUX_SESSION" \
        --arg close_proof "$CLOSE_PROOF_TXT" \
        --arg after_pid "$AFTER_PID" \
        --arg after_window_id "$AFTER_WINDOW_ID" \
        --arg after_captured_at "$AFTER_CAPTURED_AT" \
        --arg after_log "$AFTER_LOG" \
        --arg restore_elapsed_seconds "$RESTORE_ELAPSED_SECONDS" \
        --argjson probe_used "$PROBE_USED" \
        --arg probe_start "$PROBE_START_LOG" \
        --arg probe_check "$PROBE_CHECK_LOG" \
        --arg probe_cleanup "$PROBE_CLEANUP_LOG" \
        '{
            status: $status, failure: $failure, target_path: $target_path, label: $label,
            socket_label: $socket_label, isolated: $isolated,
            kill_holder: (if $kill_holder then {order: $kill_order, server_pid: $killed_server_pid} else null end),
            run_dir: $run_dir, data_dir: $data_dir,
            before: {pid: $before_pid, window_id: $before_window_id, captured_at: $before_captured_at,
                     screenshot: ($run_dir + "/before-close.png"), launch_log: $before_log,
                     tmux_session: $before_tmux_session},
            closed: {proof_text: $close_proof},
            after: {pid: $after_pid, window_id: $after_window_id, captured_at: $after_captured_at,
                    screenshot: ($run_dir + "/after-reopen.png"), launch_log: $after_log,
                    restore_elapsed_seconds: $restore_elapsed_seconds},
            tmux_probe: (if $probe_used then {start_log: $probe_start, check_log: $probe_check,
                                              cleanup_log: $probe_cleanup} else null end)
        }' >"$SUMMARY_PATH"
}

run_drill() {
    : >"$ROWS_PATH"
    build_products_once
    record_static_row all mixed_window "terminal mode is process-wide (TerminalMultiplexingMode.resolve) until S1b-1, so one window cannot hold tmux and Ghostty-split tiles together"
    local pass
    for pass in $(passes_to_run); do
        run_drill_pass "$pass"
    done
    SUMMARY_WRITTEN=true
    write_drill_summary "completed" ""
    log "Drill complete. Summary: $SUMMARY_PATH"
}

build_products_once() {
    if [[ "$NO_BUILD" == false ]]; then
        log "Building debug products once for every pass..."
        (cd "$REPO_ROOT" && swift build)
    fi
    WS_CLI="$(build_products_dir "$REPO_ROOT")/workspaces"
    [[ -x "$WS_CLI" ]] || fail "workspaces CLI not built at $WS_CLI"
    [[ "$WS_CLI" != *"'"* ]] || fail "the CLI path contains a single quote, which the tile command queue cannot carry: $WS_CLI"
}

record_static_row() {
    jq -nc --arg pass "$1" --arg tile "$2" --arg reason "$3" \
        '{pass: $pass, tile: $tile, drivable: false, status: "not_drivable", reason: $reason}' >>"$ROWS_PATH"
}

passes_to_run() {
    if [[ ${#SELECTED_PASSES[@]} -gt 0 ]]; then
        printf '%s\n' "${SELECTED_PASSES[@]}"
    else
        printf '%s\n' "${ALL_PASSES[@]}"
    fi
}

run_drill_pass() {
    PASS_ID="$1"
    describe_pass "$PASS_ID"
    PASS_DIR="$RUN_DIR/passes/$PASS_ID"
    mkdir -p "$PASS_DIR"
    log "Pass $PASS_ID: mode=$PASS_MODE restore_flag=$PASS_FLAG kill_order=$PASS_KILL_ORDER"
    prepare_isolated_home "$SOCKET_LABEL-p$(pass_index "$PASS_ID")" "$PASS_MODE" "$PASS_FLAG"

    set_phase before
    launch_drill_app before
    wait_for_operator_scope
    wait_for_repo_id
    create_tiles
    wait_for_stub_starts
    snapshot_state before
    capture_window "$APP_PID" "$APP_WINDOW_ID" "$PASS_DIR/before-kill.png" || true

    kill_holder "$PASS_KILL_ORDER" "$TMUX_LABEL" "$PASS_DIR"
    set_phase after
    launch_drill_app after
    wait_for_restore_settle
    snapshot_state after
    capture_window "$APP_PID" "$APP_WINDOW_ID" "$PASS_DIR/after-relaunch.png" || true
    grep -iE 'restore|continuity|kill' "$APP_LOG" >"$PASS_DIR/restore-log.txt" 2>/dev/null || true
    record_pass_rows

    terminate_drill_app
    stop_isolated_server "$TMUX_LABEL"
}

describe_pass() {
    case "$1" in
        tmux-*) PASS_MODE="tmux_per_session" ;;
        ghostty-*) PASS_MODE="ghostty_managed_splits" ;;
    esac
    case "$1" in
        *-on*) PASS_FLAG="on" ;;
        *-off*) PASS_FLAG="off" ;;
    esac
    case "$1" in
        *-server) PASS_KILL_ORDER="server-first" ;;
        *) PASS_KILL_ORDER="app-first" ;;
    esac
}

set_phase() {
    printf '%s\n' "$1" >"$ISOLATED_HOME/.drill/phase"
}

launch_drill_app() {
    local phase="$1"
    local output="$PASS_DIR/launch-$phase.log"
    launch_debug_app "$output" false true
    APP_PID="$(parse_launch_pid "$output")"
    APP_WINDOW_ID="$(parse_launch_window_id "$output")"
    APP_LOG="$(parse_launch_log_path "$output")"
    [[ -n "$APP_PID" && -n "$APP_LOG" ]] || fail "pass $PASS_ID: could not parse the $phase launch pid/log"
}

drill_cli() {
    env -u TMUX -u TMUX_PANE "${ISOLATION_ENV[@]}" "$WS_CLI" "$@"
}

wait_for_operator_scope() {
    local waited=0
    until drill_cli automation workspace list --json >"$PASS_DIR/workspaces-initial.json" 2>"$PASS_DIR/operator-scope.err"; do
        ((waited < 30)) || fail "pass $PASS_ID: operator scope never answered (see $PASS_DIR/operator-scope.err)"
        sleep 1
        waited=$((waited + 1))
    done
}

wait_for_repo_id() {
    local waited=0
    REPO_ID=""
    while ((waited < 30)); do
        REPO_ID="$(drill_cli automation workspace list --json 2>/dev/null \
            | jq -r --arg path "$DRILL_REPO" '.repos[] | select((.path | rtrimstr("/")) == $path) | .repoID' \
            | sed -n 1p)"
        [[ -z "$REPO_ID" ]] || return 0
        sleep 1
        waited=$((waited + 1))
    done
    fail "pass $PASS_ID: the app never imported the scratch repo $DRILL_REPO from its isolated ~/code"
}

create_tiles() {
    if [[ "$PASS_MODE" == tmux_per_session ]]; then
        create_ws_launch_tile
    else
        record_static_row "$PASS_ID" ws_launch "ws launch always starts a tmux session; in ghostty_managed_splits the app opens its own shell instead of attaching to it"
    fi
    queue_tile_commands
    drill_cli automation repo terminal "$REPO_ID" --json >"$PASS_DIR/repo-terminal.json"
    record_static_row "$PASS_ID" cmd_t_tab "no automation verb opens a tab (routes: tile split/focus/close, input write, workspace select/create, repo terminal); cmd+t needs desktop key input, which would take focus"
}

create_ws_launch_tile() {
    drill_cli repo add "$DRILL_REPO" >"$PASS_DIR/repo-add.log"
    drill_cli ws new drill-repo drill-launch --json >"$PASS_DIR/ws-new.json"
    local workspace_id workspace_path
    workspace_id="$(jq -r '.workspaceID' "$PASS_DIR/ws-new.json")"
    workspace_path="$(jq -r '.path' "$PASS_DIR/ws-new.json")"
    drill_cli ws launch "$workspace_id" --cmd "claude --effort high" --json >"$PASS_DIR/ws-launch.json"
    select_adopted_workspace "$workspace_path"
}

select_adopted_workspace() {
    local workspace_path="$1" waited=0 app_workspace_id=""
    workspace_path="$(cd "$workspace_path" && pwd -P)"
    while ((waited < 30)); do
        app_workspace_id="$(drill_cli automation workspace list --json 2>/dev/null \
            | jq -r --arg path "$workspace_path" '.workspaces[] | select((.path | rtrimstr("/")) == $path) | .workspaceID' \
            | sed -n 1p)"
        if [[ -n "$app_workspace_id" ]]; then
            drill_cli automation workspace select "$app_workspace_id" --json >"$PASS_DIR/workspace-select.json"
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    fail "pass $PASS_ID: the app never adopted the ws launch workspace $workspace_path"
}

queue_tile_commands() {
    local queue
    queue="$ISOLATED_HOME/.drill/autorun/${DRILL_REPO//[^A-Za-z0-9]/-}"
    mkdir -p "$queue"
    printf "'%s' automation tile split --right && claude --effort medium\n" "$WS_CLI" >"$queue/01.cmd"
    printf "'%s' automation tile split --down && claude --effort low\n" "$WS_CLI" >"$queue/02.cmd"
    printf 'STUB_AGENT_TURN=held claude --effort xhigh\n' >"$queue/03.cmd"
}

wait_for_stub_starts() {
    local expected=3 waited=0 started
    [[ "$PASS_MODE" != tmux_per_session ]] || expected=4
    while ((waited < TILE_TIMEOUT_SECONDS)); do
        started="$(stub_starts | jq -s 'length')"
        ((started < expected)) || return 0
        sleep 1
        waited=$((waited + 1))
    done
    log "pass $PASS_ID: only $started of $expected stub agents started within ${TILE_TIMEOUT_SECONDS}s; recording what exists"
}

stub_starts() {
    local ledger="$ISOLATED_HOME/.claude/stub-agent-ledger.jsonl"
    [[ -f "$ledger" ]] || return 0
    jq -c 'select(.event == "start" and .source == "startup")' "$ledger"
}

snapshot_state() {
    local phase="$1"
    local database
    database="$(find "$DATA_DIR" -name local-state.sqlite -print -quit 2>/dev/null)"
    if [[ -n "$database" ]]; then
        sqlite3 -readonly -json "$database" \
            "SELECT host_session_id, session_key, terminal_mode, tmux_session_name, directory_path,
                    is_active, ended_at, run_id FROM terminal_sessions ORDER BY created_at" \
            >"$PASS_DIR/db-$phase.json" 2>"$PASS_DIR/db-$phase.err" || true
    fi
    [[ -s "$PASS_DIR/db-$phase.json" ]] || echo '[]' >"$PASS_DIR/db-$phase.json"
    tmux -L "$TMUX_LABEL" list-panes -a \
        -F '#{session_id} #{session_name} #{pane_pid} #{pane_current_command} #{pane_current_path}' \
        >"$PASS_DIR/tmux-$phase.txt" 2>&1 || true
}

wait_for_restore_settle() {
    local waited=0 missing
    while ((waited < SETTLE_SECONDS)); do
        missing=0
        while IFS= read -r conversation_id; do
            [[ -n "$(prefills_for "$conversation_id")" ]] || missing=$((missing + 1))
        done < <(stub_starts | jq -r '.conversation_id')
        ((missing > 0)) || return 0
        sleep 1
        waited=$((waited + 1))
    done
}

prefills_for() {
    local conversation_id="$1" start buffer
    for start in "$ISOLATED_HOME"/.drill/observe/shell-*.start; do
        [[ -f "$start" ]] || continue
        grep -qx 'phase=after' "$start" || continue
        buffer="${start%.start}.buffer"
        [[ -f "$buffer" ]] || continue
        if grep -qF -- "--resume $conversation_id" "$buffer"; then
            cat "$buffer"
        fi
    done
}

record_pass_rows() {
    ps -A -ww -o pid=,command= >"$PASS_DIR/.processes-after.raw"
    local spec tile effort turn
    for spec in "${DRILL_TILES[@]}"; do
        IFS='|' read -r tile effort turn <<<"$spec"
        if [[ "$tile" == ws_launch && "$PASS_MODE" != tmux_per_session ]]; then
            continue
        fi
        record_tile_row "$tile" "$effort" "$turn"
    done
    rm -f "$PASS_DIR/.processes-after.raw"
}

record_tile_row() {
    local tile="$1" effort="$2" turn="$3"
    local start conversation_id cwd host_session_id holders prefill prefill_count fresh rung hook_socket
    start="$(stub_starts | jq -c --arg effort "$effort" 'select(.effort == $effort)' | sed -n 1p)"
    if [[ -z "$start" ]]; then
        jq -nc --arg pass "$PASS_ID" --arg mode "$PASS_MODE" --arg flag "$PASS_FLAG" \
            --arg kill_order "$PASS_KILL_ORDER" --arg tile "$tile" \
            '{pass: $pass, mode: $mode, restore_flag: $flag, kill_order: $kill_order, tile: $tile,
              drivable: true, status: "not_started", expected_rung: "resume", rung_taken: null,
              prefill_text: null, reason: "the stub agent for this tile never started"}' >>"$ROWS_PATH"
        return 0
    fi
    conversation_id="$(jq -r '.conversation_id' <<<"$start")"
    cwd="$(jq -r '.cwd' <<<"$start")"
    host_session_id="$(jq -r '.host_session_id' <<<"$start")"
    holders="$(conversation_holders "$conversation_id" | tee -a "$PASS_DIR/holders-after.txt" | wc -l | tr -d ' ')"
    prefill="$(prefills_for "$conversation_id" | sed -n 1p)"
    prefill_count="$(prefills_for "$conversation_id" | grep -c . || true)"
    fresh="$(fresh_shells_in "$cwd")"
    hook_socket="$(session_start_reached_socket "$conversation_id")"
    rung="none"
    if ((holders > 0)); then
        rung="reattach"
    elif ((prefill_count > 0)); then
        rung="resume"
    elif ((fresh > 0)); then
        rung="fresh"
    fi
    jq -nc \
        --arg pass "$PASS_ID" --arg mode "$PASS_MODE" --arg flag "$PASS_FLAG" \
        --arg kill_order "$PASS_KILL_ORDER" --arg tile "$tile" --arg effort "$effort" --arg turn "$turn" \
        --arg conversation_id "$conversation_id" --arg cwd "$cwd" --arg host_session_id "$host_session_id" \
        --arg rung "$rung" --arg prefill "$prefill" --argjson prefill_count "$prefill_count" \
        --argjson holders "$holders" --argjson fresh "$fresh" --argjson hook_socket "$hook_socket" \
        --slurpfile db_before "$PASS_DIR/db-before.json" --slurpfile db_after "$PASS_DIR/db-after.json" \
        'def rows($db): [$db[0][]? | select(if $host_session_id == "" then .directory_path == $cwd
                                          else .host_session_id == $host_session_id end)];
         {pass: $pass, mode: $mode, restore_flag: $flag, kill_order: $kill_order, tile: $tile,
          drivable: true, status: "observed", effort: $effort, turn: $turn,
          conversation_id: $conversation_id, cwd: $cwd, host_session_id: $host_session_id,
          session_start_reached_hooks_socket: $hook_socket,
          expected_rung: "resume", rung_taken: $rung,
          prefill_text: (if $prefill == "" then null else $prefill end), prefill_count: $prefill_count,
          holders_after_relaunch: $holders, fresh_shells_in_cwd_after: $fresh,
          rung_basis: "reattach = a process still holds the conversation; resume = a restored shell holds `--resume <id>` on its command line; fresh = a restored shell in the tile cwd holds no resume (shared cwds over-attribute)",
          db_before: rows($db_before), db_after: rows($db_after)}' >>"$ROWS_PATH"
}

conversation_holders() {
    grep -F -- "$1" "$PASS_DIR/.processes-after.raw" \
        | awk '$2 ~ /(^|\/)claude$/ || $3 ~ /(^|\/)claude$/' || true
}

fresh_shells_in() {
    local cwd="$1" start buffer count=0
    for start in "$ISOLATED_HOME"/.drill/observe/shell-*.start; do
        [[ -f "$start" ]] || continue
        grep -qx 'phase=after' "$start" || continue
        grep -qxF "cwd=$cwd" "$start" || continue
        buffer="${start%.start}.buffer"
        if [[ ! -f "$buffer" ]] || ! grep -qF -- "--resume " "$buffer"; then
            count=$((count + 1))
        fi
    done
    echo "$count"
}

session_start_reached_socket() {
    local ledger="$ISOLATED_HOME/.claude/stub-agent-ledger.jsonl"
    jq -s --arg id "$1" \
        'any(.[]; .event == "hook" and .hook == "SessionStart" and .conversation_id == $id and .hooks_socket != "")' \
        "$ledger"
}

terminate_drill_app() {
    [[ -n "$APP_PID" ]] || return 0
    terminate_app_pid "$APP_PID" >/dev/null 2>&1 || true
    wait_for_pid_exit "$APP_PID" || kill -TERM "$APP_PID" 2>/dev/null || true
    wait_for_pid_exit "$APP_PID" || true
    APP_PID=""
}

stop_isolated_server() {
    local pid
    pid="$(isolated_server_pid "$1")"
    [[ -z "$pid" ]] || (kill_isolated_server_pid "$1" "$pid") || true
}

write_drill_summary() {
    [[ -f "$ROWS_PATH" ]] || : >"$ROWS_PATH"
    jq -n \
        --arg status "$1" \
        --arg failure "$2" \
        --arg run_dir "$RUN_DIR" \
        --arg socket_label "$SOCKET_LABEL" \
        --argjson settle_seconds "$SETTLE_SECONDS" \
        --slurpfile rows "$ROWS_PATH" \
        '{status: $status, failure: $failure, run_dir: $run_dir, socket_label_base: $socket_label,
          settle_seconds: $settle_seconds, rows: $rows}' >"$SUMMARY_PATH"
}

cleanup() {
    local exit_code=$?
    set +e

    terminate_pid_if_running "$APP_PID"
    terminate_pid_if_running "$AFTER_PID"
    terminate_pid_if_running "$BEFORE_PID"
    [[ "$PROBE_USED" == false ]] || probe cleanup >>"$PROBE_CLEANUP_LOG" 2>&1
    [[ "$ISOLATED" == true ]] || restore_preferences
    release_isolated_state

    if [[ "$SUMMARY_WRITTEN" != true && -n "$SUMMARY_PATH" && -d "$RUN_DIR" ]]; then
        if [[ "$DRILL" == true ]]; then
            write_drill_summary "failed" "$FAILURE_REASON"
        else
            write_lane_summary "failed" "$FAILURE_REASON"
        fi
    fi

    exit "$exit_code"
}

terminate_pid_if_running() {
    local pid="$1"
    [[ -n "$pid" ]] || return 0
    kill -0 "$pid" 2>/dev/null || return 0
    terminate_app_pid "$pid" >/dev/null 2>&1 || true
    wait_for_pid_exit "$pid" >/dev/null 2>&1 || true
}

restore_preferences() {
    if [[ "$PREF_LAST_SURFACE_HAD" == true ]]; then
        defaults write "$PREF_DOMAIN" mainWindow.lastSurface "$PREF_LAST_SURFACE_VALUE"
    else
        defaults delete "$PREF_DOMAIN" mainWindow.lastSurface >/dev/null 2>&1 || true
    fi

    if [[ "$PREF_CONTINUITY_MANIFEST_HAD" == true ]]; then
        defaults write "$PREF_DOMAIN" terminalContinuity.manifest.v1 "$PREF_CONTINUITY_MANIFEST_VALUE"
    else
        defaults delete "$PREF_DOMAIN" terminalContinuity.manifest.v1 >/dev/null 2>&1 || true
    fi
}

release_isolated_state() {
    local label suite socket_dir
    for label in ${USED_LABELS[@]+"${USED_LABELS[@]}"}; do
        stop_isolated_server "$label"
    done
    for suite in ${USED_SUITES[@]+"${USED_SUITES[@]}"}; do
        [[ "$suite" == "$PREFS_SUITE_PREFIX".* ]] || continue
        defaults delete "$suite" >/dev/null 2>&1 || true
    done
    for socket_dir in ${SOCKET_DIRS[@]+"${SOCKET_DIRS[@]}"}; do
        rm -f "$socket_dir/hooks.sock"
        rmdir "$socket_dir" 2>/dev/null || true
    done
}

main "$@"
