#!/bin/bash
# ==========================================================================
# lume-standalone-verify-base.sh - Boot and SSH-verify the validated base VM
# ==========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/scripts/lib/lume-standalone-common.sh"

RUN_DIR=""

usage() {
    cat <<'USAGE'
Usage: ./scripts/lume-standalone-verify-base.sh [options]

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

fail_base_verification() {
    local message="$1"
    export LUME_STANDALONE_STATUS_BASE_STATE="invalid"
    export LUME_STANDALONE_STATUS_BASE_SOURCE="$LUME_STANDALONE_BASE_SOURCE"
    export LUME_STANDALONE_STATUS_FAILURE_STAGE="verify-base"
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

    local marker_path
    marker_path="$(lume_standalone_marker_path "$LUME_STANDALONE_BASE_VM_NAME")"

    if ! "$LUME_BIN" get "$LUME_STANDALONE_BASE_VM_NAME" --storage "$LUME_STANDALONE_BASE_STORAGE_PATH" -f json >"$LUME_STANDALONE_RUN_DIR/base-get-before.json" 2>/dev/null; then
        if [[ -n "$(lume_standalone_vm_dir_path "$LUME_STANDALONE_BASE_VM_NAME" "$LUME_STANDALONE_BASE_STORAGE_PATH")" ]]; then
            fail_base_verification "A stale validated base VM directory exists but Lume cannot resolve it."
        fi
        export LUME_STANDALONE_STATUS_BASE_STATE="missing"
        export LUME_STANDALONE_STATUS_BASE_SOURCE="$LUME_STANDALONE_BASE_SOURCE"
        export LUME_STANDALONE_STATUS_FAILURE_STAGE="verify-base"
        export LUME_STANDALONE_STATUS_FAILURE_MESSAGE="No validated base VM exists yet."
        lume_standalone_set_status
        lume_standalone_fail "$LUME_STANDALONE_STATUS_FAILURE_MESSAGE"
    fi

    local current_status
    current_status="$(lume_standalone_json_field "$LUME_STANDALONE_RUN_DIR/base-get-before.json" "0.status")"
    if [[ "$current_status" != "running" ]]; then
        lume_standalone_start_cli_vm \
            "$LUME_STANDALONE_BASE_VM_NAME" \
            "$LUME_STANDALONE_BASE_STORAGE_PATH" \
            "" \
            "$LUME_STANDALONE_RUN_DIR/base-run.log" \
            "$LUME_STANDALONE_RUN_DIR/base-run.pid"
        sleep 2

        if ! "$LUME_BIN" get "$LUME_STANDALONE_BASE_VM_NAME" --storage "$LUME_STANDALONE_BASE_STORAGE_PATH" -f json >"$LUME_STANDALONE_RUN_DIR/base-run.json" 2>/dev/null; then
            fail_base_verification "Could not start the validated base VM."
        fi
    fi

    if ! lume_standalone_wait_for_vm_ssh \
        "$LUME_STANDALONE_BASE_VM_NAME" \
        "$LUME_STANDALONE_BASE_STORAGE_PATH" \
        "$LUME_STANDALONE_DEFAULT_BASE_READY_TIMEOUT_SECONDS" \
        "$LUME_STANDALONE_RUN_DIR/base-get-running.json" \
        "$LUME_STANDALONE_RUN_DIR/ssh-probe-base.txt" \
        "WORKSPACES_LUME_BASE_OK"
    then
        fail_base_verification "Validated base VM did not reach SSH readiness."
    fi

    if ! "$LUME_BIN" stop "$LUME_STANDALONE_BASE_VM_NAME" --storage "$LUME_STANDALONE_BASE_STORAGE_PATH" >"$LUME_STANDALONE_RUN_DIR/base-stop.log" 2>&1; then
        fail_base_verification "Validated base VM reached SSH but did not stop cleanly."
    fi

    "$LUME_BIN" get "$LUME_STANDALONE_BASE_VM_NAME" --storage "$LUME_STANDALONE_BASE_STORAGE_PATH" -f json >"$LUME_STANDALONE_RUN_DIR/base-get-before.json"

    export LUME_STANDALONE_MARKER_VALIDATION_STATE="ready"
    export LUME_STANDALONE_MARKER_VALIDATED_AT="$(lume_standalone_iso8601_now)"
    export LUME_STANDALONE_MARKER_FAILURE_MESSAGE=""
    lume_standalone_write_marker "$LUME_STANDALONE_BASE_VM_NAME" "ready" ""

    export LUME_STANDALONE_STATUS_BASE_STATE="ready"
    export LUME_STANDALONE_STATUS_BASE_SOURCE="$LUME_STANDALONE_BASE_SOURCE"
    export LUME_STANDALONE_STATUS_BASE_VERIFIED_AT="$LUME_STANDALONE_MARKER_VALIDATED_AT"
    export LUME_STANDALONE_STATUS_FAILURE_STAGE=""
    export LUME_STANDALONE_STATUS_FAILURE_MESSAGE=""
    lume_standalone_set_status
    lume_standalone_copy_daemon_logs

    if lume_standalone_marker_is_valid "$marker_path"; then
        lume_standalone_log "Validated base VM is SSH-ready: $LUME_STANDALONE_BASE_VM_NAME"
    fi
}

main "$@"
