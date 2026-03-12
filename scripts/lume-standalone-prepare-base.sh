#!/bin/bash
# ==========================================================================
# lume-standalone-prepare-base.sh - Prepare the canonical validated base VM
# ==========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/scripts/lib/lume-standalone-common.sh"

RUN_DIR=""
PREPARE_LOG=""
UNATTENDED_DEBUG_DIR=""

usage() {
    cat <<'USAGE'
Usage: ./scripts/lume-standalone-prepare-base.sh [options]

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

cleanup_on_failure() {
    local exit_code="$?"
    if [[ "$exit_code" -eq 0 ]]; then
        return
    fi

    export LUME_STANDALONE_STATUS_BASE_STATE="invalid"
    export LUME_STANDALONE_STATUS_BASE_SOURCE="$LUME_STANDALONE_BASE_SOURCE"
    export LUME_STANDALONE_STATUS_FAILURE_STAGE="prepare-base"
    export LUME_STANDALONE_STATUS_FAILURE_MESSAGE="Failed to prepare the validated base VM."
    lume_standalone_set_status

    export LUME_STANDALONE_MARKER_VALIDATION_STATE="invalid"
    export LUME_STANDALONE_MARKER_VALIDATED_AT=""
    export LUME_STANDALONE_MARKER_FAILURE_MESSAGE="$LUME_STANDALONE_STATUS_FAILURE_MESSAGE"
    lume_standalone_write_marker "$LUME_STANDALONE_BASE_VM_NAME" "invalid" "$LUME_STANDALONE_STATUS_FAILURE_MESSAGE" || true
    lume_standalone_copy_daemon_logs
}

prepare_from_registry() {
    lume_standalone_log "Pulling validated base from registry image $LUME_STANDALONE_IMAGE_REFERENCE"
    if "$LUME_BIN" pull "$LUME_STANDALONE_IMAGE_REFERENCE" "$LUME_STANDALONE_BASE_VM_NAME" \
        --registry ghcr.io \
        --organization workspacemanager \
        --storage "$LUME_STANDALONE_BASE_STORAGE_PATH" \
        >"$PREPARE_LOG" 2>&1
    then
        export LUME_STANDALONE_BASE_SOURCE="registry"
        export LUME_STANDALONE_SOURCE_KIND="pulledImage"
        return 0
    fi

    lume_standalone_log "Registry pull failed, falling back to stock macOS prepare."
    cat "$PREPARE_LOG" >>"$LUME_STANDALONE_RUN_DIR/prepare-base-fallback.log" || true
    return 1
}

prepare_from_stock() {
    export LUME_STANDALONE_BASE_SOURCE="stock-prepare"
    export LUME_STANDALONE_SOURCE_KIND="stockPrepared"
    export LUME_STANDALONE_STATUS_BASE_SOURCE="$LUME_STANDALONE_BASE_SOURCE"
    lume_standalone_set_status
    lume_standalone_log \
        "Preparing validated base from stock macOS install using unattended profile '$LUME_STANDALONE_UNATTENDED_CONFIG_LABEL'."
    TERM="${TERM:-xterm-256color}" "$LUME_BIN" create "$LUME_STANDALONE_BASE_VM_NAME" \
        --os macos \
        --cpu 4 \
        --memory 8GB \
        --disk-size 50GB \
        --display 1024x768 \
        --ipsw latest \
        --unattended "$LUME_STANDALONE_UNATTENDED_CONFIG_PATH" \
        --storage "$LUME_STANDALONE_BASE_STORAGE_PATH" \
        --network nat \
        --no-display \
        --debug \
        --debug-dir "$UNATTENDED_DEBUG_DIR" \
        >"$PREPARE_LOG" 2>&1
}

stock_prepare_error_is_retryable() {
    local log_path="$1"
    grep -qi "network connection was lost" "$log_path" \
        || grep -qi "timed out" "$log_path" \
        || grep -qi "temporarily unavailable" "$log_path"
}

prepare_from_stock_with_retries() {
    local max_attempts="${LUME_STANDALONE_DEFAULT_PREPARE_RETRIES}"
    local attempt=1

    while (( attempt <= max_attempts )); do
        PREPARE_LOG="$LUME_STANDALONE_RUN_DIR/prepare-base-stock-attempt-${attempt}.log"
        if prepare_from_stock; then
            return 0
        fi

        if (( attempt == max_attempts )); then
            return 1
        fi

        if ! stock_prepare_error_is_retryable "$PREPARE_LOG"; then
            return 1
        fi

        lume_standalone_log \
            "Stock base preparation attempt ${attempt}/${max_attempts} failed with a retryable network error. Cleaning up and retrying."
        lume_standalone_remove_vm "$LUME_STANDALONE_BASE_VM_NAME" "$LUME_STANDALONE_BASE_STORAGE_PATH"
        if [[ -n "$(lume_standalone_vm_dir_path "$LUME_STANDALONE_BASE_VM_NAME" "$LUME_STANDALONE_BASE_STORAGE_PATH")" ]]; then
            lume_standalone_move_stale_vm_dir "$LUME_STANDALONE_BASE_VM_NAME" "$LUME_STANDALONE_BASE_STORAGE_PATH"
        fi
        sleep 5
        (( attempt += 1 ))
    done

    return 1
}

main() {
    parse_args "$@"
    lume_standalone_setup_run_dir "$RUN_DIR"
    trap cleanup_on_failure EXIT
    lume_standalone_require_lume
    lume_standalone_detect_host_profile
    lume_standalone_resolve_image
    lume_standalone_resolve_unattended_config

    PREPARE_LOG="$LUME_STANDALONE_RUN_DIR/prepare-base.log"
    UNATTENDED_DEBUG_DIR="$LUME_STANDALONE_RUN_DIR/unattended-debug"
    export LUME_STANDALONE_UNATTENDED_DEBUG_DIR="$UNATTENDED_DEBUG_DIR"
    export LUME_STANDALONE_STATUS_BASE_STATE="preparing"
    export LUME_STANDALONE_STATUS_BASE_SOURCE="$LUME_STANDALONE_BASE_SOURCE"
    export LUME_STANDALONE_STATUS_FAILURE_STAGE=""
    export LUME_STANDALONE_STATUS_FAILURE_MESSAGE=""
    lume_standalone_set_status

    mkdir -p "$LUME_STANDALONE_BASE_STORAGE_PATH"
    mkdir -p "$UNATTENDED_DEBUG_DIR"

    if "$LUME_BIN" get "$LUME_STANDALONE_BASE_VM_NAME" --storage "$LUME_STANDALONE_BASE_STORAGE_PATH" -f json >"$LUME_STANDALONE_RUN_DIR/base-get-before.json" 2>/dev/null; then
        lume_standalone_log "Removing existing validated base VM before rebuild."
        lume_standalone_remove_vm "$LUME_STANDALONE_BASE_VM_NAME" "$LUME_STANDALONE_BASE_STORAGE_PATH"
    fi

    if [[ -n "$(lume_standalone_vm_dir_path "$LUME_STANDALONE_BASE_VM_NAME" "$LUME_STANDALONE_BASE_STORAGE_PATH")" ]]; then
        lume_standalone_move_stale_vm_dir "$LUME_STANDALONE_BASE_VM_NAME" "$LUME_STANDALONE_BASE_STORAGE_PATH"
    fi

    if [[ -n "$LUME_STANDALONE_IMAGE_REFERENCE" ]]; then
        if ! prepare_from_registry; then
            prepare_from_stock_with_retries
        fi
    else
        prepare_from_stock_with_retries
    fi

    if [[ "$PREPARE_LOG" != "$LUME_STANDALONE_RUN_DIR/prepare-base.log" ]]; then
        cp "$PREPARE_LOG" "$LUME_STANDALONE_RUN_DIR/prepare-base.log"
    fi

    "$LUME_BIN" get "$LUME_STANDALONE_BASE_VM_NAME" --storage "$LUME_STANDALONE_BASE_STORAGE_PATH" -f json >"$LUME_STANDALONE_RUN_DIR/base-get-before.json"

    export LUME_STANDALONE_MARKER_VALIDATION_STATE="invalid"
    export LUME_STANDALONE_MARKER_VALIDATED_AT=""
    export LUME_STANDALONE_MARKER_FAILURE_MESSAGE="Base prepared but not yet verified."
    lume_standalone_write_marker "$LUME_STANDALONE_BASE_VM_NAME" "invalid" "Base prepared but not yet verified."

    export LUME_STANDALONE_STATUS_BASE_STATE="preparing"
    export LUME_STANDALONE_STATUS_BASE_SOURCE="$LUME_STANDALONE_BASE_SOURCE"
    export LUME_STANDALONE_STATUS_FAILURE_STAGE=""
    export LUME_STANDALONE_STATUS_FAILURE_MESSAGE=""
    lume_standalone_set_status
    lume_standalone_copy_daemon_logs
}

main "$@"
