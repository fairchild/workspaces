#!/bin/bash
# ==========================================================================
# lume-host-macos-smoke.sh - Real-host macOS VM smoke for the debug app
# ==========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/scripts/lib/lume-standalone-common.sh"
PREFLIGHT_SCRIPT="$REPO_ROOT/scripts/lume-host-preflight.sh"
STANDALONE_VALIDATE_SCRIPT="$REPO_ROOT/scripts/lume-standalone-validate.sh"
LAUNCH_SCRIPT="$REPO_ROOT/scripts/launch-dev.sh"
CAPTURE_SCRIPT="$REPO_ROOT/scripts/capture-window.sh"
OUTPUT_ROOT="$REPO_ROOT/output/lume-host-smoke"
DEFAULT_TIMEOUT_SECONDS=$((90 * 60))
DEFAULT_INACTIVITY_SECONDS=$((10 * 60))

SKIP_PREFLIGHT=false
SKIP_BUILD=false
TOTAL_TIMEOUT_SECONDS="$DEFAULT_TIMEOUT_SECONDS"
INACTIVITY_TIMEOUT_SECONDS="$DEFAULT_INACTIVITY_SECONDS"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$OUTPUT_ROOT/$TIMESTAMP"
RUN_LINK="$OUTPUT_ROOT/latest"
RUN_STATUS="failed"
FAILURE_MESSAGE=""
APP_PID=""
LAUNCH_LOG_PATH=""
SMOKE_REPO_PATH=""
WORKSPACE_NAME=""
WORKSPACE_PATH=""
VM_NAME=""
VM_STORAGE_PATH=""
REMOTE_ID=""
SSH_PROBE_PATH=""
LUME_VALIDATED_BASE_STORAGE=""
DETACHED_LAUNCH_LOG_PATH=""

log() {
    echo "[$(date +%H:%M:%S)] $*"
}

fail() {
    echo "ERROR: $*" >&2
    FAILURE_MESSAGE="$*"
    exit 1
}

usage() {
    cat <<'USAGE'
Usage: ./scripts/lume-host-macos-smoke.sh [options]

Options:
  --skip-preflight         Skip the fast host preflight check
  --no-build               Reuse the current debug binary
  --timeout-seconds <n>    Total timeout for the full smoke (default: 5400)
  --inactivity-seconds <n> Fail if no event or daemon-log progress occurs (default: 600)
  --help, -h               Show this help
USAGE
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip-preflight)
                SKIP_PREFLIGHT=true
                shift
                ;;
            --no-build)
                SKIP_BUILD=true
                shift
                ;;
            --timeout-seconds)
                [[ $# -ge 2 ]] || fail "--timeout-seconds requires a value"
                TOTAL_TIMEOUT_SECONDS="$2"
                shift 2
                ;;
            --inactivity-seconds)
                [[ $# -ge 2 ]] || fail "--inactivity-seconds requires a value"
                INACTIVITY_TIMEOUT_SECONDS="$2"
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
}

setup_run_dir() {
    mkdir -p "$RUN_DIR"
    mkdir -p "$OUTPUT_ROOT"
    ln -sfn "$RUN_DIR" "$RUN_LINK"
    SSH_PROBE_PATH="$RUN_DIR/ssh-probe.txt"
}

cleanup_app() {
    if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" >/dev/null 2>&1; then
        kill "$APP_PID" >/dev/null 2>&1 || true
        sleep 1
    fi
    pkill -f "$REPO_ROOT/.build/arm64-apple-macosx/debug/WorkspaceManager" >/dev/null 2>&1 || true
}

copy_supporting_logs() {
    if [[ -n "$LAUNCH_LOG_PATH" && -f "$LAUNCH_LOG_PATH" ]]; then
        cp "$LAUNCH_LOG_PATH" "$RUN_DIR/launch.log"
    fi

    if [[ -f /tmp/lume_daemon.log ]]; then
        cp /tmp/lume_daemon.log "$RUN_DIR/lume_daemon.log"
    fi

    if [[ -f /tmp/lume_daemon.error.log ]]; then
        cp /tmp/lume_daemon.error.log "$RUN_DIR/lume_daemon.error.log"
    fi

    if [[ -n "$DETACHED_LAUNCH_LOG_PATH" && -f "$DETACHED_LAUNCH_LOG_PATH" ]]; then
        cp "$DETACHED_LAUNCH_LOG_PATH" "$RUN_DIR/detached-launch.log"
    fi
}

cleanup_success_artifacts() {
    local lume_bin="$HOME/.local/bin/lume"
    if [[ -n "$VM_NAME" && -x "$lume_bin" ]]; then
        local -a lume_args=()
        if [[ -n "${VM_STORAGE_PATH:-}" ]]; then
            lume_args+=("--storage" "$VM_STORAGE_PATH")
        fi
        "$lume_bin" stop "$VM_NAME" "${lume_args[@]}" >/dev/null 2>&1 || true
        "$lume_bin" delete "$VM_NAME" "${lume_args[@]}" --force >/dev/null 2>&1 || true
    fi

    if [[ -n "$WORKSPACE_PATH" && -d "$WORKSPACE_PATH" ]]; then
        chmod -R u+w "$WORKSPACE_PATH" >/dev/null 2>&1 || true
        rm -rf "$WORKSPACE_PATH" >/dev/null 2>&1 || true
    fi

    if [[ -n "$SMOKE_REPO_PATH" && -d "$SMOKE_REPO_PATH" ]]; then
        chmod -R u+w "$SMOKE_REPO_PATH" >/dev/null 2>&1 || true
        rm -rf "$SMOKE_REPO_PATH" >/dev/null 2>&1 || true
    fi
}

cleanup_prior_smoke_vms() {
    local lume_bin="$HOME/.local/bin/lume"
    [[ -x "$lume_bin" ]] || return 0
    [[ -n "$LUME_VALIDATED_BASE_STORAGE" ]] || return 0

    python3 - "$lume_bin" "$LUME_VALIDATED_BASE_STORAGE" <<'PY'
import json
import subprocess
import sys

lume_bin, storage = sys.argv[1:]
proc = subprocess.run(
    [lume_bin, "ls", "--storage", storage, "-f", "json"],
    capture_output=True,
    text=True,
)
if proc.returncode != 0:
    raise SystemExit(0)

try:
    payload = json.loads(proc.stdout)
except Exception:
    raise SystemExit(0)

for entry in payload:
    name = entry.get("name") or ""
    if not name.startswith("workspaces-lume-smoke-"):
        continue

    subprocess.run([lume_bin, "stop", name, "--storage", storage], capture_output=True, text=True)
    subprocess.run(
        [lume_bin, "delete", name, "--storage", storage, "--force"],
        capture_output=True,
        text=True,
    )
PY
}

write_summary() {
    local elapsed_seconds="$1"
    local outcome_message="$2"
    cat >"$RUN_DIR/summary.md" <<EOF
# Lume Host macOS Smoke

- Outcome: $RUN_STATUS
- Message: $outcome_message
- Repo path: ${SMOKE_REPO_PATH:-unknown}
- Workspace name: ${WORKSPACE_NAME:-unknown}
- Workspace path: ${WORKSPACE_PATH:-unknown}
- VM name: ${VM_NAME:-unknown}
- Remote ID: ${REMOTE_ID:-unknown}
- Elapsed seconds: $elapsed_seconds
- Events: $RUN_DIR/events.jsonl
- Launch log: ${LAUNCH_LOG_PATH:-unknown}
- Detached launch log source: ${DETACHED_LAUNCH_LOG_PATH:-unknown}
- Detached launch log artifact: $RUN_DIR/detached-launch.log
- SSH probe: ${SSH_PROBE_PATH:-unknown}
EOF
}

refresh_state_from_events() {
    if [[ -f "$RUN_DIR/events.jsonl" ]]; then
        eval "$(read_event_state)"
        WORKSPACE_PATH="${workspace_path:-$WORKSPACE_PATH}"
        REMOTE_ID="${remote_id:-$REMOTE_ID}"
        VM_NAME="${vm_name:-$VM_NAME}"
        VM_STORAGE_PATH="${vm_storage_path:-$VM_STORAGE_PATH}"
        DETACHED_LAUNCH_LOG_PATH="${launch_log_path:-$DETACHED_LAUNCH_LOG_PATH}"
    fi
}

finalize_and_exit() {
    local exit_code="$1"
    local started_at="$2"
    local message="$3"
    local elapsed_seconds
    elapsed_seconds=$(( $(date +%s) - started_at ))

    refresh_state_from_events
    copy_supporting_logs

    if [[ "$RUN_STATUS" == "passed" ]]; then
        cleanup_success_artifacts
    fi

    cleanup_app
    write_summary "$elapsed_seconds" "$message"
    log "$message"
    log "Run directory: $RUN_DIR"
    exit "$exit_code"
}

on_exit() {
    local exit_code="$?"
    trap - EXIT
    if [[ "$exit_code" -ne 0 && "$RUN_STATUS" != "passed" ]]; then
        finalize_and_exit "$exit_code" "$STARTED_AT" "${FAILURE_MESSAGE:-Smoke run failed.}"
    fi
}

create_disposable_repo() {
    mkdir -p "$HOME/code"
    SMOKE_REPO_PATH="$HOME/code/workspaces-lume-smoke-$TIMESTAMP"
    mkdir -p "$SMOKE_REPO_PATH"
    (
        cd "$SMOKE_REPO_PATH"
        git init >/dev/null
        git config user.name "WorkspaceManager Smoke" >/dev/null
        git config user.email "smoke@local.invalid" >/dev/null
        printf "# Lume host smoke\n\nCreated %s\n" "$TIMESTAMP" >README.md
        printf "print('smoke')\n" >smoke.py
        git add README.md smoke.py
        git commit -m "Initial smoke fixture" >/dev/null
    )
}

run_preflight_if_needed() {
    if [[ "$SKIP_PREFLIGHT" == true ]]; then
        return
    fi

    local -a args=()
    if [[ "$SKIP_BUILD" == true ]]; then
        args+=("--no-build")
    fi

    (
        cd "$REPO_ROOT"
        "$PREFLIGHT_SCRIPT" "${args[@]}"
    ) | tee "$RUN_DIR/preflight.log"

    lume_standalone_require_lume
    lume_standalone_detect_host_profile
    LUME_VALIDATED_BASE_STORAGE="$LUME_STANDALONE_BASE_STORAGE_PATH"
    cleanup_prior_smoke_vms
}

run_standalone_validation_gate() {
    lume_standalone_require_lume
    lume_standalone_detect_host_profile
    lume_standalone_resolve_image
    lume_standalone_resolve_unattended_config

    local marker_path
    marker_path="$(lume_standalone_marker_path "$LUME_STANDALONE_BASE_VM_NAME")"

    if lume_standalone_marker_is_valid "$marker_path"; then
        log "Reusing validated standalone Lume base: $LUME_STANDALONE_BASE_VM_NAME"
        printf "Reused validated standalone Lume base: %s\n" "$LUME_STANDALONE_BASE_VM_NAME" >"$RUN_DIR/standalone-validate.log"
        return
    fi

    (
        cd "$REPO_ROOT"
        "$STANDALONE_VALIDATE_SCRIPT"
    ) | tee "$RUN_DIR/standalone-validate.log"
}

launch_automated_app() {
    WORKSPACE_NAME="lume-smoke-$TIMESTAMP"
    local events_path="$RUN_DIR/events.jsonl"
    local app_data_dir="$RUN_DIR/app-data"
    local launch_output
    local -a args=(
        "--data-dir" "$app_data_dir"
        "--clean-data"
        "--window-timeout" "20"
        "--env" "WORKSPACES_DISABLE_AUTO_IMPORT=1"
        "--env" "WORKSPACES_AUTOMATION_MODE=host-lume-macos-smoke"
        "--env" "WORKSPACES_AUTOMATION_REPO_PATH=$SMOKE_REPO_PATH"
        "--env" "WORKSPACES_AUTOMATION_WORKSPACE_NAME=$WORKSPACE_NAME"
        "--env" "WORKSPACES_AUTOMATION_EVENTS_PATH=$events_path"
    )
    if [[ "$SKIP_BUILD" == true ]]; then
        args+=("--no-build")
    fi

    launch_output="$(
        cd "$REPO_ROOT"
        "$LAUNCH_SCRIPT" "${args[@]}" 2>&1 | tee "$RUN_DIR/launch-command.log"
    )"

    APP_PID="$(printf '%s\n' "$launch_output" | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | tail -n 1)"
    LAUNCH_LOG_PATH="$(printf '%s\n' "$launch_output" | sed -n 's/.*Log file: \(.*\)$/\1/p' | tail -n 1)"

    [[ -n "$APP_PID" ]] || fail "Could not determine WorkspaceManager pid from launch output."
    [[ -n "$LAUNCH_LOG_PATH" ]] || fail "Could not determine WorkspaceManager log path from launch output."

    (
        cd "$REPO_ROOT"
        "$CAPTURE_SCRIPT" --output "$RUN_DIR/01-launch.png"
    ) >/dev/null 2>&1 || true
}

file_mtime() {
    local target="$1"
    if [[ -e "$target" ]]; then
        stat -f %m "$target"
    else
        echo 0
    fi
}

lume_cli_provisioning_active() {
    local identifier="${VM_NAME:-$REMOTE_ID}"
    [[ -n "$identifier" ]] || return 1
    ps -axo command= | grep -F "lume create" | grep -F "$identifier" >/dev/null 2>&1
}

read_event_state() {
    python3 - "$RUN_DIR/events.jsonl" <<'PY'
import json
import shlex
import sys
from pathlib import Path

path = Path(sys.argv[1])
state = {
    "status": "pending",
    "failure_message": "",
    "workspace_name": "",
    "workspace_path": "",
    "remote_id": "",
    "provider_id": "",
    "vm_name": "",
    "vm_storage_path": "",
    "launch_log_path": "",
    "last_event_type": "",
}

if path.exists():
    for raw_line in path.read_text().splitlines():
        if not raw_line.strip():
            continue
        event = json.loads(raw_line)
        state["last_event_type"] = event.get("type", "")
        if event.get("workspaceName"):
            state["workspace_name"] = event["workspaceName"]
        if event.get("workspacePath"):
            state["workspace_path"] = event["workspacePath"]
        if event.get("remoteID"):
            state["remote_id"] = event["remoteID"]
        if event.get("providerID"):
            state["provider_id"] = event["providerID"]
        lume_metadata = event.get("lumeMetadata") or {}
        if lume_metadata.get("vmName"):
            state["vm_name"] = lume_metadata["vmName"]
        if lume_metadata.get("storagePath"):
            state["vm_storage_path"] = lume_metadata["storagePath"]
        if lume_metadata.get("launchLogPath"):
            state["launch_log_path"] = lume_metadata["launchLogPath"]
        if event.get("type") == "failure":
            state["status"] = "failure"
            state["failure_message"] = event.get("message", "")
        elif event.get("type") == "workspace_active":
            state["status"] = "active"

for key, value in state.items():
    if not isinstance(value, str):
        value = str(value)
    print(f"{key}={shlex.quote(value)}")
PY
}

capture_final_screenshot() {
    (
        cd "$REPO_ROOT"
        "$CAPTURE_SCRIPT" --output "$RUN_DIR/02-final.png"
    ) >/dev/null 2>&1 || true
}

run_ssh_probe() {
    local lume_bin="$HOME/.local/bin/lume"
    [[ -x "$lume_bin" ]] || fail "Lume CLI not found at $lume_bin"
    [[ -n "$VM_NAME" ]] || fail "workspace_active did not include a vmName"

    local attempt
    local max_attempts=5

    : >"$SSH_PROBE_PATH"

    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        local -a ssh_args=("ssh" "$VM_NAME")
        if [[ -n "${VM_STORAGE_PATH:-}" ]]; then
            ssh_args+=("--storage" "$VM_STORAGE_PATH")
        fi
        ssh_args+=(
            "--user" "$LUME_STANDALONE_SSH_USER"
            "--password" "$LUME_STANDALONE_SSH_PASSWORD"
            "printf WORKSPACES_LUME_SMOKE_OK"
        )

        if "$lume_bin" "${ssh_args[@]}" >"$SSH_PROBE_PATH" 2>&1; then
            if grep -q "WORKSPACES_LUME_SMOKE_OK" "$SSH_PROBE_PATH"; then
                return 0
            fi
        fi

        if (( attempt < max_attempts )); then
            sleep 5
        fi
    done

    if [[ -s "$SSH_PROBE_PATH" ]]; then
        fail "Host-side lume ssh probe did not print the success sentinel."
    fi
    fail "Host-side lume ssh probe failed."
}

monitor_until_complete() {
    local started_at="$1"
    local last_progress_at
    last_progress_at="$(date +%s)"

    while true; do
        if [[ -n "$APP_PID" ]] && ! kill -0 "$APP_PID" >/dev/null 2>&1; then
            fail "WorkspaceManager exited before the host smoke completed."
        fi

        local newest_progress_epoch=0
        local events_mtime daemon_mtime daemon_error_mtime
        events_mtime="$(file_mtime "$RUN_DIR/events.jsonl")"
        daemon_mtime="$(file_mtime /tmp/lume_daemon.log)"
        daemon_error_mtime="$(file_mtime /tmp/lume_daemon.error.log)"
        newest_progress_epoch="$events_mtime"
        if (( daemon_mtime > newest_progress_epoch )); then
            newest_progress_epoch="$daemon_mtime"
        fi
        if (( daemon_error_mtime > newest_progress_epoch )); then
            newest_progress_epoch="$daemon_error_mtime"
        fi
        if (( newest_progress_epoch > last_progress_at )); then
            last_progress_at="$newest_progress_epoch"
        fi

        eval "$(read_event_state)"

        if [[ "${status:-pending}" == "failure" ]]; then
            WORKSPACE_PATH="${workspace_path:-}"
            REMOTE_ID="${remote_id:-}"
            VM_NAME="${vm_name:-}"
            VM_STORAGE_PATH="${vm_storage_path:-$VM_STORAGE_PATH}"
            capture_final_screenshot
            fail "App reported failure: ${failure_message:-Unknown failure}"
        fi

        if [[ "${status:-pending}" == "active" ]]; then
            WORKSPACE_PATH="${workspace_path:-}"
            REMOTE_ID="${remote_id:-}"
            VM_NAME="${vm_name:-}"
            VM_STORAGE_PATH="${vm_storage_path:-$VM_STORAGE_PATH}"
            capture_final_screenshot
            run_ssh_probe
            RUN_STATUS="passed"
            return
        fi

        local now
        now="$(date +%s)"
        if lume_cli_provisioning_active; then
            last_progress_at="$now"
        fi

        if (( now - started_at > TOTAL_TIMEOUT_SECONDS )); then
            capture_final_screenshot
            fail "Timed out waiting for a macOS VM workspace to become active."
        fi

        if (( now - last_progress_at > INACTIVITY_TIMEOUT_SECONDS )); then
            capture_final_screenshot
            fail "Timed out waiting for new app or Lume daemon progress."
        fi

        sleep 5
    done
}

main() {
    parse_args "$@"
    setup_run_dir
    STARTED_AT="$(date +%s)"
    trap on_exit EXIT

    run_standalone_validation_gate
    run_preflight_if_needed
    create_disposable_repo
    launch_automated_app
    monitor_until_complete "$STARTED_AT"
    finalize_and_exit 0 "$STARTED_AT" "Smoke run completed successfully."
}

main "$@"
