#!/bin/bash
# ==========================================================================
# lume-standalone-preflight.sh - Validate the local Lume runtime directly
# ==========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/scripts/lib/lume-standalone-common.sh"

RUN_DIR=""

usage() {
    cat <<'USAGE'
Usage: ./scripts/lume-standalone-preflight.sh [options]

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

main() {
    parse_args "$@"
    lume_standalone_setup_run_dir "$RUN_DIR"
    lume_standalone_require_lume
    lume_standalone_detect_host_profile
    lume_standalone_resolve_image
    lume_standalone_resolve_unattended_config

    mkdir -p "$LUME_STANDALONE_BASE_STORAGE_PATH" "$LUME_STANDALONE_SMOKE_STORAGE_PATH"
    local free_gb
    free_gb="$(lume_standalone_free_gb_for_path "$LUME_STANDALONE_BASE_STORAGE_PATH")"
    if [[ -z "$free_gb" || "$free_gb" -lt "$LUME_STANDALONE_MIN_FREE_GB" ]]; then
        export LUME_STANDALONE_STATUS_FAILURE_STAGE="disk"
        export LUME_STANDALONE_STATUS_FAILURE_MESSAGE="Need at least ${LUME_STANDALONE_MIN_FREE_GB}GB free for standalone Lume validation."
        export LUME_STANDALONE_STATUS_BASE_STATE="missing"
        export LUME_STANDALONE_STATUS_BASE_SOURCE="$LUME_STANDALONE_BASE_SOURCE"
        lume_standalone_set_status
        lume_standalone_fail "$LUME_STANDALONE_STATUS_FAILURE_MESSAGE"
    fi

    "$LUME_BIN" ls -f json --storage "$LUME_STANDALONE_BASE_STORAGE_PATH" >"$LUME_STANDALONE_RUN_DIR/preflight-ls.json"
    /usr/bin/curl --silent --show-error --fail \
        "$(lume_standalone_daemon_base_url)/host/status" \
        >"$LUME_STANDALONE_RUN_DIR/preflight-daemon-host-status.json"

    "$LUME_BIN" ipsw >"$LUME_STANDALONE_RUN_DIR/preflight-ipsw.txt"

    export LUME_STANDALONE_STATUS_BASE_STATE="missing"
    export LUME_STANDALONE_STATUS_BASE_SOURCE="$LUME_STANDALONE_BASE_SOURCE"
    export LUME_STANDALONE_STATUS_CLONE_STATE="not_run"
    export LUME_STANDALONE_STATUS_FAILURE_STAGE=""
    export LUME_STANDALONE_STATUS_FAILURE_MESSAGE=""
    lume_standalone_set_status

    cat <<EOF
Standalone Lume preflight passed.
- Host profile: $LUME_STANDALONE_HOST_PROFILE_DISPLAY_NAME
- Base VM name: $LUME_STANDALONE_BASE_VM_NAME
- Base source: $LUME_STANDALONE_BASE_SOURCE
- Base storage: $LUME_STANDALONE_BASE_STORAGE_PATH
- Smoke storage: $LUME_STANDALONE_SMOKE_STORAGE_PATH
- Unattended profile: $LUME_STANDALONE_UNATTENDED_CONFIG_LABEL
- Lume binary: $LUME_BIN
- Free disk under validated base storage: ${free_gb}GB
- Run directory: $LUME_STANDALONE_RUN_DIR
EOF
}

main "$@"
