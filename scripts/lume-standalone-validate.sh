#!/bin/bash
# ==========================================================================
# lume-standalone-validate.sh - End-to-end standalone Lume validation gate
# ==========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/scripts/lib/lume-standalone-common.sh"

PREFLIGHT_SCRIPT="$REPO_ROOT/scripts/lume-standalone-preflight.sh"
PREPARE_SCRIPT="$REPO_ROOT/scripts/lume-standalone-prepare-base.sh"
VERIFY_SCRIPT="$REPO_ROOT/scripts/lume-standalone-verify-base.sh"
CLONE_SCRIPT="$REPO_ROOT/scripts/lume-standalone-clone-smoke.sh"

RUN_DIR=""
RUN_STATUS="failed"
FAILURE_MESSAGE=""

usage() {
    cat <<'USAGE'
Usage: ./scripts/lume-standalone-validate.sh [options]

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

write_summary() {
    python3 - "$(lume_standalone_status_path)" "$LUME_STANDALONE_RUN_DIR/summary.md" "$RUN_STATUS" "$FAILURE_MESSAGE" <<'PY'
import json
import sys
from pathlib import Path

status_path = Path(sys.argv[1])
summary_path = Path(sys.argv[2])
run_status = sys.argv[3]
failure_message = sys.argv[4]
payload = json.loads(status_path.read_text()) if status_path.exists() else {}

summary_path.write_text(
    "\n".join(
        [
            "# Lume Standalone Validation",
            "",
            f"- Outcome: {run_status}",
            f"- Message: {failure_message or 'Validation passed.'}",
            f"- Host profile: {payload.get('hostProfile') or 'unknown'}",
            f"- Base VM name: {payload.get('baseVMName') or 'unknown'}",
            f"- Storage path: {payload.get('storagePath') or 'unknown'}",
            f"- Base state: {payload.get('baseState') or 'unknown'}",
            f"- Base source: {payload.get('baseSource') or 'unknown'}",
            f"- Base prep network: {__import__('os').environ.get('LUME_STANDALONE_PREPARE_NETWORK', 'unknown')}",
            f"- Runtime network: {__import__('os').environ.get('LUME_STANDALONE_RUN_NETWORK', 'unknown')}",
            f"- Unattended config: {payload.get('unattendedConfig') or 'unknown'}",
            f"- Unattended debug dir: {payload.get('unattendedDebugDir') or 'none'}",
            f"- Base verified at: {payload.get('baseVerifiedAt') or 'unknown'}",
            f"- Clone state: {payload.get('cloneState') or 'unknown'}",
            f"- Failure stage: {payload.get('failureStage') or 'none'}",
            f"- Failure message: {payload.get('failureMessage') or 'none'}",
            f"- Status JSON: {status_path}",
        ]
    ) + "\n"
)
PY
}

finalize() {
    lume_standalone_copy_daemon_logs
    write_summary
    lume_standalone_log "Standalone validation $RUN_STATUS"
    lume_standalone_log "Run directory: $LUME_STANDALONE_RUN_DIR"
}

main() {
    parse_args "$@"
    lume_standalone_setup_run_dir "$RUN_DIR"
    lume_standalone_require_lume
    lume_standalone_detect_host_profile
    lume_standalone_resolve_image
    lume_standalone_resolve_unattended_config

    if ! "$PREFLIGHT_SCRIPT" --run-dir "$LUME_STANDALONE_RUN_DIR"; then
        FAILURE_MESSAGE="Standalone preflight failed."
        finalize
        exit 1
    fi

    local marker_path marker_state
    marker_path="$(lume_standalone_marker_path "$LUME_STANDALONE_BASE_VM_NAME")"
    marker_state="$(lume_standalone_marker_state "$marker_path")"

    if [[ "$marker_state" == "invalid" ]]; then
        lume_standalone_log "Validated-base manifest is marked invalid; attempting live verification before rebuild."
    fi

    if ! "$VERIFY_SCRIPT" --run-dir "$LUME_STANDALONE_RUN_DIR"; then
        if lume_standalone_legacy_base_exists; then
            lume_standalone_log "Importing legacy base into isolated validated storage before rebuild."
            if lume_standalone_import_legacy_base >"$LUME_STANDALONE_RUN_DIR/legacy-base-import.log" 2>&1; then
                if "$VERIFY_SCRIPT" --run-dir "$LUME_STANDALONE_RUN_DIR"; then
                    :
                else
                    lume_standalone_log "Imported legacy base did not verify cleanly; falling back to fresh preparation."
                fi
            else
                lume_standalone_log "Legacy base import failed; falling back to fresh preparation."
            fi
        fi
    fi

    if ! lume_standalone_marker_is_valid "$marker_path"; then
        lume_standalone_log "Existing validated base is missing or invalid; preparing a fresh base."
        if ! "$PREPARE_SCRIPT" --run-dir "$LUME_STANDALONE_RUN_DIR"; then
            FAILURE_MESSAGE="Validated base preparation failed."
            finalize
            exit 1
        fi
        if ! "$VERIFY_SCRIPT" --run-dir "$LUME_STANDALONE_RUN_DIR"; then
            FAILURE_MESSAGE="Validated base verification failed after preparation."
            finalize
            exit 1
        fi
    fi

    if ! "$CLONE_SCRIPT" --run-dir "$LUME_STANDALONE_RUN_DIR"; then
        FAILURE_MESSAGE="Validated base clone smoke failed."
        finalize
        exit 1
    fi

    RUN_STATUS="passed"
    FAILURE_MESSAGE=""
    finalize
}

main "$@"
