#!/bin/bash
# ==========================================================================
# lume-standalone-clone-smoke.sh - Clone smoke for the validated base VM
# ==========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/scripts/lib/lume-standalone-common.sh"

RUN_DIR=""
CLONE_NAME=""

usage() {
    cat <<'USAGE'
Usage: ./scripts/lume-standalone-clone-smoke.sh [options]

Options:
  --run-dir <path>  Reuse an existing standalone run directory
  --help, -h        Show this help
USAGE
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --run-dir)
                [[ $# -ge 2 ]] || lume_standalone_fail "--run-dir requires a value"
                RUN_DIR="$2"
                shift 2
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                lume_standalone_fail "Unknown argument: $1"
                ;;
        esac
    done
}

mark_clone_failure() {
    local message="$1"
    export LUME_STANDALONE_STATUS_CLONE_STATE="failed"
    export LUME_STANDALONE_STATUS_BASE_STATE="invalid"
    export LUME_STANDALONE_STATUS_BASE_SOURCE="$LUME_STANDALONE_BASE_SOURCE"
    export LUME_STANDALONE_STATUS_FAILURE_STAGE="clone-smoke"
    export LUME_STANDALONE_STATUS_FAILURE_MESSAGE="$message"
    lume_standalone_set_status

    export LUME_STANDALONE_MARKER_VALIDATION_STATE="invalid"
    export LUME_STANDALONE_MARKER_VALIDATED_AT=""
    export LUME_STANDALONE_MARKER_FAILURE_MESSAGE="$message"
    lume_standalone_write_marker "$LUME_STANDALONE_BASE_VM_NAME" "invalid" "$message" || true
    lume_standalone_copy_daemon_logs
    lume_standalone_fail "$message"
}

main() {
    parse_args "$@"
    lume_standalone_setup_run_dir "$RUN_DIR"
    lume_standalone_require_lume
    lume_standalone_detect_host_profile
    lume_standalone_resolve_image
    lume_standalone_resolve_unattended_config

    local marker_path shared_dir shared_probe_path
    marker_path="$(lume_standalone_marker_path "$LUME_STANDALONE_BASE_VM_NAME")"
    if ! lume_standalone_marker_is_valid "$marker_path"; then
        mark_clone_failure "The validated base VM has not passed standalone verification."
    fi

    export LUME_STANDALONE_STATUS_BASE_STATE="ready"
    export LUME_STANDALONE_STATUS_BASE_SOURCE="$LUME_STANDALONE_BASE_SOURCE"
    export LUME_STANDALONE_STATUS_BASE_VERIFIED_AT="$(lume_standalone_marker_field "$marker_path" "validatedAt")"

    CLONE_NAME="${LUME_STANDALONE_BASE_VM_NAME}-clone-smoke-$(date +%Y%m%d-%H%M%S)"
    shared_dir="$LUME_STANDALONE_RUN_DIR/shared-dir"
    shared_probe_path="$LUME_STANDALONE_RUN_DIR/shared-dir-probe.txt"
    mkdir -p "$shared_dir"
    mkdir -p "$LUME_STANDALONE_BASE_STORAGE_PATH"
    printf "WORKSPACES_SHARED_DIR_OK\n" >"$shared_dir/host-sentinel.txt"

    "$LUME_BIN" clone "$LUME_STANDALONE_BASE_VM_NAME" "$CLONE_NAME" \
        --source-storage "$LUME_STANDALONE_BASE_STORAGE_PATH" \
        --dest-storage "$LUME_STANDALONE_BASE_STORAGE_PATH" \
        >"$LUME_STANDALONE_RUN_DIR/clone-create.log" 2>&1 \
        || mark_clone_failure "Could not clone the validated base VM."

    lume_standalone_start_cli_vm \
        "$CLONE_NAME" \
        "$LUME_STANDALONE_BASE_STORAGE_PATH" \
        "$shared_dir" \
        "$LUME_STANDALONE_RUN_DIR/clone-run.log" \
        "$LUME_STANDALONE_RUN_DIR/clone-run.pid"
    sleep 2

    if ! lume_standalone_wait_for_vm_ssh \
        "$CLONE_NAME" \
        "$LUME_STANDALONE_BASE_STORAGE_PATH" \
        "$LUME_STANDALONE_DEFAULT_CLONE_READY_TIMEOUT_SECONDS" \
        "$LUME_STANDALONE_RUN_DIR/clone-get-running.json" \
        "$LUME_STANDALONE_RUN_DIR/ssh-probe-clone.txt" \
        "WORKSPACES_LUME_CLONE_OK"
    then
        mark_clone_failure "The cloned VM did not reach SSH readiness."
    fi

    local clone_ip
    clone_ip="$(lume_standalone_best_vm_ip \
        "$CLONE_NAME" \
        "$LUME_STANDALONE_BASE_STORAGE_PATH" \
        "$LUME_STANDALONE_RUN_DIR/clone-get-running.json" \
        "$LUME_STANDALONE_RUN_DIR/.tmp-${CLONE_NAME}-cli.json" \
        "$LUME_STANDALONE_RUN_DIR/.tmp-${CLONE_NAME}-daemon.json" \
        || true)"

    if ! lume_standalone_exec_remote \
        "$CLONE_NAME" \
        "$LUME_STANDALONE_BASE_STORAGE_PATH" \
        "$clone_ip" \
        "cat '/Volumes/My Shared Files/host-sentinel.txt'" \
        "$shared_probe_path"
    then
        mark_clone_failure "The cloned VM did not expose the shared host directory."
    fi

    if ! grep -q "WORKSPACES_SHARED_DIR_OK" "$shared_probe_path"; then
        mark_clone_failure "The cloned VM could not read the shared host sentinel file."
    fi

    "$LUME_BIN" stop "$CLONE_NAME" --storage "$LUME_STANDALONE_BASE_STORAGE_PATH" >"$LUME_STANDALONE_RUN_DIR/clone-stop.log" 2>&1 || true
    "$LUME_BIN" delete "$CLONE_NAME" --storage "$LUME_STANDALONE_BASE_STORAGE_PATH" --force >"$LUME_STANDALONE_RUN_DIR/clone-delete.log" 2>&1 || true

    export LUME_STANDALONE_STATUS_CLONE_STATE="passed"
    export LUME_STANDALONE_STATUS_FAILURE_STAGE=""
    export LUME_STANDALONE_STATUS_FAILURE_MESSAGE=""
    lume_standalone_set_status
    lume_standalone_copy_daemon_logs
}

main "$@"
