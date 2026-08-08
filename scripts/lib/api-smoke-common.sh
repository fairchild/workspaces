#!/bin/bash
# ==========================================================================
# api-smoke-common.sh - shared setup/teardown for the api/desktop smoke family
# ==========================================================================
#
# scripts/api-create-smoke.sh, scripts/api-select-smoke.sh,
# scripts/api-desktop-ui-smoke.sh, and scripts/desktop-ui-smoke.sh each drove
# the debug app through a near-identical launch/cleanup harness (#1236).
# This is the one copy: run-dir + synthetic-root setup, disposable-repo
# fixture, app launch/kill, and a single unconditional-cleanup finalize path
# built on #1247's trap/finalize shape.
#
# Cleanup here is unconditional by design: it runs on every outcome (pass,
# fail, signal) — a failing run is when leftover app processes and worktrees
# cost the most, so `--keep-artifacts` is the only opt-out, not RUN_STATUS.
#
# api-select-smoke.sh deliberately keeps its own local read_workspace_field/
# event_index/wait_for_event and post-select assertion logic rather than
# routing through smoke_read_event_field below — that region overlaps
# in-flight work in PR #1265 (typed wait primitives), so this lib only
# touches api-select-smoke.sh's setup/teardown blocks.
#
# Callers: `set -euo pipefail`, define SCRIPT_DIR/REPO_ROOT, then
# `source "$SCRIPT_DIR/lib/api-smoke-common.sh"` (which sources
# synthetic-root.sh in turn — no separate source line needed).

SMOKE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=synthetic-root.sh
source "$SMOKE_LIB_DIR/synthetic-root.sh"

smoke_log() {
    echo "[$(date +%H:%M:%S)] $*"
}

smoke_fail() {
    echo "ERROR: $*" >&2
    FAILURE_MESSAGE="$*"
    exit 1
}

# smoke_init — reset per-run state to its starting values and stamp
# STARTED_AT. Call once at the top of main(), right after parse_args.
smoke_init() {
    RUN_STATUS="failed"
    FAILURE_MESSAGE=""
    FINALIZED=false
    APP_PID=""
    LAUNCH_LOG_PATH=""
    SMOKE_REPO_PATH=""
    STARTED_AT="$(date +%s)"
}

# smoke_setup_run_dir — create the run dir, point `latest` at it, and
# establish the WORKSPACES_SYNTHETIC_ROOT isolation boundary inside it (so a
# created worktree can never leak into the owner's real ~/workspaces).
# Requires RUN_DIR/RUN_LINK; sets EVENTS_PATH.
smoke_setup_run_dir() {
    mkdir -p "$RUN_DIR"
    ln -sfn "$RUN_DIR" "$RUN_LINK"
    EVENTS_PATH="$RUN_DIR/events.jsonl"
    synthetic_root_ensure "$RUN_DIR/workspaces-root" \
        || smoke_fail "Could not establish WORKSPACES_SYNTHETIC_ROOT."
}

# smoke_create_disposable_repo <readme-label> — a throwaway git repo inside
# the run dir (so a red run leaves zero residue outside it). Sets
# SMOKE_REPO_PATH. Requires RUN_DIR/TIMESTAMP.
smoke_create_disposable_repo() {
    local label="$1"
    SMOKE_REPO_PATH="$(mktemp -d "$RUN_DIR/smoke-repo-XXXXXX")"
    (
        cd "$SMOKE_REPO_PATH" || exit 1
        git init >/dev/null
        git config user.name "WorkspaceManager Smoke" >/dev/null
        git config user.email "smoke@local.invalid" >/dev/null
        printf "# %s\n\nCreated %s\n" "$label" "$TIMESTAMP" >README.md
        git add README.md
        git commit -m "Initial smoke fixture" >/dev/null
    )
}

# smoke_launch_app [--env KEY=VALUE]... — launch the debug app headless-safe
# with the isolation boundary and milestone-stream env wired; any extra
# arguments are appended verbatim to launch-dev.sh's argv (each lane's own
# --env pairs, e.g. the automation driver selection). Sets APP_PID and
# LAUNCH_LOG_PATH from the launch output. Requires LAUNCH_SCRIPT/REPO_ROOT/
# RUN_DIR/SKIP_BUILD/WORKSPACE_NAME/EVENTS_PATH/SMOKE_REPO_PATH.
smoke_launch_app() {
    synthetic_root_require || smoke_fail "Refusing to launch without WORKSPACES_SYNTHETIC_ROOT."
    local app_data_dir="$RUN_DIR/app-data"
    local -a args=(
        "--no-activate"
        "--data-dir" "$app_data_dir"
        "--clean-data"
        "--window-timeout" "20"
        "--env" "WORKSPACES_DISABLE_AUTO_IMPORT=1"
        "--env" "WORKSPACES_SYNTHETIC_ROOT=$WORKSPACES_SYNTHETIC_ROOT"
        "--env" "WORKSPACES_AUTOMATION_MODE=desktop-ui-smoke"
        "--env" "WORKSPACES_AUTOMATION_REPO_PATH=$SMOKE_REPO_PATH"
        "--env" "WORKSPACES_AUTOMATION_WORKSPACE_NAME=$WORKSPACE_NAME"
        "--env" "WORKSPACES_AUTOMATION_EVENTS_PATH=$EVENTS_PATH"
    )
    local extra
    for extra in "$@"; do
        args+=("--env" "$extra")
    done
    [[ "$SKIP_BUILD" == true ]] && args+=("--no-build")

    local launch_output
    launch_output="$(
        cd "$REPO_ROOT" || exit 1
        "$LAUNCH_SCRIPT" "${args[@]}" 2>&1 | tee "$RUN_DIR/launch-command.log"
    )"
    APP_PID="$(printf '%s\n' "$launch_output" | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | tail -n 1)"
    LAUNCH_LOG_PATH="$(printf '%s\n' "$launch_output" | sed -n 's/.*Log file: \(.*\)$/\1/p' | tail -n 1)"
    [[ -n "$APP_PID" ]] || smoke_fail "Could not determine WorkspaceManager pid from launch output."
}

smoke_cleanup_app() {
    if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" >/dev/null 2>&1; then
        kill "$APP_PID" >/dev/null 2>&1 || true
        sleep 1
    fi
    pkill -f "$REPO_ROOT/.build/arm64-apple-macosx/debug/WorkspaceManager" >/dev/null 2>&1 || true
}

smoke_cleanup_repo() {
    [[ "$KEEP_ARTIFACTS" == true ]] && return 0
    if [[ -n "$SMOKE_REPO_PATH" && -d "$SMOKE_REPO_PATH" ]]; then
        chmod -R u+w "$SMOKE_REPO_PATH" >/dev/null 2>&1 || true
        rm -rf "$SMOKE_REPO_PATH" >/dev/null 2>&1 || true
    fi
}

# smoke_cleanup_created_worktree — the app creates the workspace as a git
# worktree under the synthetic workspaces root inside the run dir; remove it
# using the path the app reported in the workspace_created milestone. Tolerant
# of a torn/missing events.jsonl (app killed before writing anything).
smoke_cleanup_created_worktree() {
    [[ "$KEEP_ARTIFACTS" == true ]] && return 0
    [[ -f "$EVENTS_PATH" ]] || return 0
    local workspace_path
    workspace_path="$(smoke_read_event_field workspacePath workspace_created)"
    [[ -n "$workspace_path" && -d "$workspace_path" ]] || return 0
    chmod -R u+w "$workspace_path" >/dev/null 2>&1 || true
    rm -rf "$workspace_path" >/dev/null 2>&1 || true

    # Prune the now-empty per-repo container the worktree lived in.
    local repo_container
    repo_container="$(dirname "$workspace_path")"
    if [[ -d "$repo_container" && -z "$(ls -A "$repo_container" 2>/dev/null)" ]]; then
        rmdir "$repo_container" >/dev/null 2>&1 || true
    fi
}

# smoke_read_event_field <field> <event-type> — last value of <field> on an
# event whose type == <event-type> in $EVENTS_PATH, or "".
smoke_read_event_field() {
    python3 "$SMOKE_LIB_DIR/smoke_events.py" read-field "$EVENTS_PATH" "$1" "$2"
}

# smoke_event_index <event-type> — 0-based index of the first event of that
# type in $EVENTS_PATH, or -1.
smoke_event_index() {
    python3 "$SMOKE_LIB_DIR/smoke_events.py" event-index "$EVENTS_PATH" "$1"
}

# smoke_wait_for_event <event-type> — block until the milestone appears in
# $EVENTS_PATH, surfacing an app-side failure milestone immediately rather
# than waiting out the timeout. Bounded by $TOTAL_TIMEOUT_SECONDS.
smoke_wait_for_event() {
    local event_type="$1" deadline=$(( $(date +%s) + TOTAL_TIMEOUT_SECONDS ))
    while (( $(date +%s) < deadline )); do
        if [[ "$(smoke_event_index "$event_type")" != "-1" ]]; then
            return 0
        fi
        if [[ "$(smoke_event_index failure)" != "-1" ]]; then
            smoke_fail "App reported a failure milestone: $(smoke_read_event_field message failure)"
        fi
        sleep 1
    done
    smoke_fail "Timed out waiting for milestone: $event_type"
}

# smoke_finalize_and_exit <exit-code> [<message>] — single finalize path for
# every outcome (pass, fail, signal). Clears all traps first so a late signal
# takes its default action instead of re-entering; FINALIZED guards the one
# command window before the traps drop. Cleanup is unconditional (see file
# header). If the caller defined a `smoke_write_summary <exit-code>
# <message>` function, it runs after cleanup so it can report what cleanup
# did.
smoke_finalize_and_exit() {
    trap - EXIT TERM INT HUP
    local exit_code="$1"
    local message="${2:-}"
    if [[ "$FINALIZED" == true ]]; then
        exit "$exit_code"
    fi
    FINALIZED=true

    smoke_cleanup_app
    smoke_cleanup_repo
    smoke_cleanup_created_worktree

    if declare -F smoke_write_summary >/dev/null 2>&1; then
        smoke_write_summary "$exit_code" "$message"
    fi

    [[ -n "$message" ]] && smoke_log "$message"
    smoke_log "Run directory: $RUN_DIR"
    exit "$exit_code"
}

# smoke_on_exit — EXIT trap. Catches a nonzero exit that fell through without
# an explicit smoke_finalize_and_exit call (e.g. `set -e` aborting on an
# unguarded command) and routes it through the same finalize path.
smoke_on_exit() {
    local exit_code="$?"
    trap - EXIT
    if [[ "$exit_code" -ne 0 && "$RUN_STATUS" != "passed" ]]; then
        smoke_finalize_and_exit "$exit_code" "${FAILURE_MESSAGE:-Smoke run failed.}"
    fi
}

# smoke_on_signal <name> <number> — TERM/INT/HUP do not fire the EXIT trap (a
# plain `kill`, and what CI timeouts send), so route them into the same
# finalize path with the conventional 128+signum exit code.
smoke_on_signal() {
    local signal_name="$1" signal_number="$2"
    RUN_STATUS="interrupted"
    smoke_finalize_and_exit "$((128 + signal_number))" "Smoke run interrupted by SIG${signal_name}."
}

# smoke_install_traps — wire the unconditional-cleanup trap set. Call once
# setup is ready to be torn down (right after parse_args/smoke_init).
smoke_install_traps() {
    trap smoke_on_exit EXIT
    trap 'smoke_on_signal TERM 15' TERM
    trap 'smoke_on_signal INT 2' INT
    trap 'smoke_on_signal HUP 1' HUP
}
