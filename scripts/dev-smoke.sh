#!/bin/bash
# ==========================================================================
# dev-smoke.sh - Launch the debug app, require a visible window, capture proof
# ==========================================================================
#
# This is the fast local self-test loop for startup sanity:
# - launches the latest debug build through launch-dev.sh
# - requires the debug app to stay alive and open a visible window
# - captures a window-only screenshot as lightweight evidence
#
# Usage:
#   ./scripts/dev-smoke.sh
#   ./scripts/dev-smoke.sh --no-build
#   ./scripts/dev-smoke.sh --no-activate
#
# ==========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LAUNCH_SCRIPT="$REPO_ROOT/scripts/launch-dev.sh"
CAPTURE_SCRIPT="$REPO_ROOT/scripts/capture-window.sh"
OUTPUT_DIR="$REPO_ROOT/output/dev-smoke"

NO_BUILD=false
NO_ACTIVATE=false
TRUST_MISE=false
CLEAN_DATA=false
WINDOW_TIMEOUT_SECONDS=10
SCREENSHOT_PATH=""

log() {
    echo "[$(date +%H:%M:%S)] $*"
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
Usage: ./scripts/dev-smoke.sh [options]

Options:
  --no-build             Skip swift build and reuse the current debug binary
  --no-activate          Shared-desktop launch mode (do not foreground the app)
  --clean-data           Remove the isolated dev data root before launch
  --trust-mise           Trust this repo's .mise.toml before launch
  --window-timeout <s>   Require a visible window within this many seconds (default: 10)
  --help, -h             Show this help
USAGE
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-build)
                NO_BUILD=true
                shift
                ;;
            --no-activate)
                NO_ACTIVATE=true
                shift
                ;;
            --clean-data)
                CLEAN_DATA=true
                shift
                ;;
            --trust-mise)
                TRUST_MISE=true
                shift
                ;;
            --window-timeout)
                [[ $# -ge 2 ]] || fail "--window-timeout requires a value"
                WINDOW_TIMEOUT_SECONDS="$2"
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

run_launch() {
    local -a launch_args=("--window-timeout" "$WINDOW_TIMEOUT_SECONDS")
    [[ "$NO_BUILD" == true ]] && launch_args+=("--no-build")
    [[ "$NO_ACTIVATE" == true ]] && launch_args+=("--no-activate")
    [[ "$CLEAN_DATA" == true ]] && launch_args+=("--clean-data")
    [[ "$TRUST_MISE" == true ]] && launch_args+=("--trust-mise")

    (
        cd "$REPO_ROOT"
        "$LAUNCH_SCRIPT" "${launch_args[@]}"
    )
}

capture_evidence() {
    mkdir -p "$OUTPUT_DIR"
    SCREENSHOT_PATH="$OUTPUT_DIR/dev-smoke-$(date +%Y%m%d-%H%M%S).png"

    (
        cd "$REPO_ROOT"
        if "$CAPTURE_SCRIPT" --output "$SCREENSHOT_PATH"; then
            exit 0
        fi

        log "Window-only capture failed; falling back to full-screen capture."
        screencapture -x "$SCREENSHOT_PATH"
    )
}

main() {
    parse_args "$@"
    run_launch
    capture_evidence

    local latest_log
    latest_log="$(ls -1t "$REPO_ROOT"/.dev-data/logs/launch-dev-*.log 2>/dev/null | head -n 1 || true)"

    log "Dev smoke passed."
    log "Screenshot: $SCREENSHOT_PATH"
    if [[ -n "$latest_log" ]]; then
        log "Launch log: $latest_log"
    fi
}

main "$@"
