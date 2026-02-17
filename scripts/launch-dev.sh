#!/bin/bash
# ==========================================================================
# launch-dev.sh - Launch the latest local debug build with explicit data-root isolation
# ==========================================================================
#
# Why this script exists:
# - Avoid stale bundle confusion:
#   `build/WorkspaceManager.app` can be outdated unless explicitly rebuilt/copied.
#   This script always launches `.build/arm64-apple-macosx/debug/WorkspaceManager`
#   after an optional `swift build`.
#
# - Dogfood isolation design:
#   We intentionally isolate app runtime state (SwiftData store + logs) into a
#   workspace-local directory by default (`.dev-data/workspacemanager`).
#   This mirrors our product direction in `backlog/isolation-strategies.md`:
#   explicit, inspectable runtime boundaries.
#
# Isolation model (important distinction):
# 1) Execution sandbox isolation:
#    An outer runner (agent/tooling/CI sandbox) can restrict process privileges.
#    Example: blocking writes to `~/Library/Application Support`.
#
# 2) App data-root isolation (this script):
#    We control where WorkspaceManager persists state via `WORKSPACES_DATA_DIR`.
#    This keeps state scoped, reproducible, and resettable per environment.
#
# Practical usage:
# - Default mode (recommended for dev + reproducibility):
#     ./scripts/launch-dev.sh
#   Builds and launches latest debug binary with local isolated data root.
#
# - Use host Application Support (less isolated, closer to installed behavior):
#     ./scripts/launch-dev.sh --use-app-support
#
# - UI fixture mode for deterministic screenshots:
#     ./scripts/launch-dev.sh --fixture --clean-data
#
# - Shared-desktop mode (do not steal foreground focus at launch):
#     ./scripts/launch-dev.sh --no-activate
#
# ==========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="WorkspaceManager"
DEBUG_BINARY="$REPO_ROOT/.build/arm64-apple-macosx/debug/$APP_NAME"
INSTALLED_APP_BINARY="/Applications/$APP_NAME.app/Contents/MacOS/$APP_NAME"
DEFAULT_DATA_DIR="$REPO_ROOT/.dev-data/workspacemanager"
LOG_DIR="$REPO_ROOT/.dev-data/logs"

DO_BUILD=true
KILL_EXISTING=true
RUN_IN_BACKGROUND=true
USE_APP_SUPPORT=false
FIXTURE_MODE=false
CLEAN_DATA=false
NO_ACTIVATE_ON_LAUNCH=false
DATA_DIR="$DEFAULT_DATA_DIR"
LOG_PATH=""
APP_PID=""
declare -a ENV_VARS=()

usage() {
    cat <<'USAGE'
Usage: ./scripts/launch-dev.sh [options]

Options:
  --no-build           Skip swift build and launch existing debug binary
  --no-kill            Do not stop existing WorkspaceManager processes
  --foreground         Run attached to current terminal (no nohup)
  --use-app-support    Do not set WORKSPACES_DATA_DIR (use platform defaults)
  --data-dir <path>    Override isolated data root (default: ./.dev-data/workspacemanager)
  --fixture            Enable deterministic UI fixture mode
  --no-activate        Do not call NSApp.activate on startup (shared-desktop safe)
  --clean-data         Remove selected data dir before launch
  --help, -h           Show this help

Isolation notes:
- Default launch sets WORKSPACES_DATA_DIR to a workspace-local path.
- This simulates explicit state isolation and avoids leaking dev state into
  global user directories.
- It does not emulate full OS sandboxing; it isolates app persistence scope.
USAGE
}

log() {
    echo "[$(date +%H:%M:%S)] $*"
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-build)
                DO_BUILD=false
                shift
                ;;
            --no-kill)
                KILL_EXISTING=false
                shift
                ;;
            --foreground)
                RUN_IN_BACKGROUND=false
                shift
                ;;
            --use-app-support)
                USE_APP_SUPPORT=true
                shift
                ;;
            --data-dir)
                [[ $# -ge 2 ]] || fail "--data-dir requires a value"
                DATA_DIR="$2"
                shift 2
                ;;
            --fixture)
                FIXTURE_MODE=true
                shift
                ;;
            --no-activate)
                NO_ACTIVATE_ON_LAUNCH=true
                shift
                ;;
            --clean-data)
                CLEAN_DATA=true
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

verify_repo_root() {
    if [[ ! -f "$REPO_ROOT/Package.swift" ]]; then
        fail "Package.swift not found at repo root: $REPO_ROOT"
    fi
}

build_if_requested() {
    if [[ "$DO_BUILD" == true ]]; then
        log "Building latest debug binary..."
        (
            cd "$REPO_ROOT"
            swift build --product "$APP_NAME"
        )
    fi
}

verify_debug_binary() {
    if [[ ! -x "$DEBUG_BINARY" ]]; then
        fail "Debug binary not found: $DEBUG_BINARY"
    fi
}

list_instances_for_binary() {
    local binary_path="$1"
    ps -axo pid=,command= | awk -v target="$binary_path" '$2 == target { print $1 " " $2 }'
}

ensure_no_installed_app_instance() {
    local installed_instances
    installed_instances="$(list_instances_for_binary "$INSTALLED_APP_BINARY")"
    if [[ -n "$installed_instances" ]]; then
        log "Unexpected installed app instance detected:"
        while IFS= read -r line; do
            [[ -n "$line" ]] && log "  - $line"
        done <<< "$installed_instances"
        fail "Stale install process detected at $INSTALLED_APP_BINARY"
    fi
}

stop_existing_if_requested() {
    if [[ "$KILL_EXISTING" != true ]]; then
        return
    fi

    log "Stopping any running WorkspaceManager instances..."
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    pkill -f "$INSTALLED_APP_BINARY" >/dev/null 2>&1 || true
    pkill -f "$REPO_ROOT/build/WorkspaceManager.app/Contents/MacOS/WorkspaceManager" >/dev/null 2>&1 || true
    pkill -f "$DEBUG_BINARY" >/dev/null 2>&1 || true
    sleep 1
}

expand_home_prefix() {
    local path="$1"
    if [[ "$path" == "~" ]]; then
        printf "%s\n" "$HOME"
        return
    fi
    if [[ "$path" == "~/"* ]]; then
        printf "%s\n" "$HOME/${path#~/}"
        return
    fi
    printf "%s\n" "$path"
}

configure_data_root() {
    if [[ "$USE_APP_SUPPORT" == true ]]; then
        return
    fi

    DATA_DIR="$(expand_home_prefix "$DATA_DIR")"
    ENV_VARS+=("WORKSPACES_DATA_DIR=$DATA_DIR")

    mkdir -p "$DATA_DIR"
    if [[ "$CLEAN_DATA" == true ]]; then
        log "Cleaning isolated data dir: $DATA_DIR"
        rm -rf "$DATA_DIR"
        mkdir -p "$DATA_DIR"
    fi
}

configure_fixture_mode() {
    if [[ "$FIXTURE_MODE" == true ]]; then
        ENV_VARS+=("WORKSPACES_UI_FIXTURE=1")
        ENV_VARS+=("WORKSPACES_DISABLE_AUTO_IMPORT=1")
    fi
}

configure_launch_behavior() {
    if [[ "$NO_ACTIVATE_ON_LAUNCH" == true ]]; then
        ENV_VARS+=("WORKSPACES_NO_ACTIVATE_ON_LAUNCH=1")
    fi
}

prepare_log_path() {
    mkdir -p "$LOG_DIR"
    LOG_PATH="$LOG_DIR/launch-dev-$(date +%Y%m%d-%H%M%S).log"
}

print_launch_plan() {
    log "Launching: $DEBUG_BINARY"
    if [[ ${#ENV_VARS[@]} -gt 0 ]]; then
        log "Environment overrides:"
        for entry in "${ENV_VARS[@]}"; do
            log "  - $entry"
        done
    else
        log "Environment overrides: (none)"
    fi
}

dump_recent_log_and_fail() {
    local reason="$1"
    log "$reason"
    tail -n 40 "$LOG_PATH" || true
    fail "WorkspaceManager exited during startup"
}

verify_background_process() {
    sleep 1
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        dump_recent_log_and_fail "Launch failed. Last log lines:"
    fi

    sleep 1
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        dump_recent_log_and_fail "Launch failed during warmup. Last log lines:"
    fi

    local app_command
    app_command="$(ps -p "$APP_PID" -o command= | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]].*$//')"
    if [[ "$app_command" != "$DEBUG_BINARY" ]]; then
        log "Unexpected executable for pid=$APP_PID: $app_command"
        fail "Launch verification failed: running process is not debug binary"
    fi

    ensure_no_installed_app_instance

    # Guardrail against stale app confusion: surface any other WorkspaceManager
    # processes that are not our expected debug binary.
    local other_instances
    other_instances="$(ps -axo pid=,command= | awk -v expected="$DEBUG_BINARY" '$2 ~ /WorkspaceManager$/ && $2 != expected { print $1 " " $2 }')"
    if [[ -n "$other_instances" ]]; then
        log "Warning: additional WorkspaceManager processes detected:"
        while IFS= read -r line; do
            [[ -n "$line" ]] && log "  - $line"
        done <<< "$other_instances"
    fi
}

launch_background() {
    pushd "$REPO_ROOT" >/dev/null
    nohup env "${ENV_VARS[@]}" "$DEBUG_BINARY" >"$LOG_PATH" 2>&1 &
    APP_PID=$!
    popd >/dev/null

    verify_background_process
    log "WorkspaceManager running (pid=$APP_PID)"
    log "Verified executable path: $DEBUG_BINARY"
    log "Log file: $LOG_PATH"
}

launch_foreground() {
    log "Foreground mode. Logs will stream in this terminal."
    ensure_no_installed_app_instance
    (
        cd "$REPO_ROOT"
        exec env "${ENV_VARS[@]}" "$DEBUG_BINARY"
    )
}

main() {
    parse_args "$@"
    verify_repo_root
    build_if_requested
    verify_debug_binary
    stop_existing_if_requested
    configure_data_root
    configure_fixture_mode
    configure_launch_behavior
    prepare_log_path
    print_launch_plan

    if [[ "$RUN_IN_BACKGROUND" == true ]]; then
        launch_background
    else
        launch_foreground
    fi
}

main "$@"
