#!/bin/bash
# ==========================================================================
# lume-pr-validation.sh - End-to-end PR validation chain for Lume integration
# ==========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

STANDALONE_RUN_DIR=""
TIMEOUT_SECONDS=$((8 * 60 * 60))
POLL_SECONDS=300
RUN_DIR=""
STATUS="failed"
MESSAGE=""
declare -a REQUIRED_STEPS=(build-ghosttykit swift-build swift-tests ui-smoke host-preflight host-smoke)
declare -a OPTIONAL_STEPS=(dev-smoke)

usage() {
    cat <<'USAGE'
Usage: ./scripts/lume-pr-validation.sh --standalone-run-dir <path> [options]

Options:
  --standalone-run-dir <path>  Existing standalone validation run directory to watch
  --timeout-seconds <n>        Total wait timeout for standalone completion (default: 28800)
  --poll-seconds <n>           Poll interval while waiting (default: 300)
  --help, -h                   Show this help
USAGE
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --standalone-run-dir)
                [[ $# -ge 2 ]] || { echo "--standalone-run-dir requires a value" >&2; exit 1; }
                STANDALONE_RUN_DIR="$2"
                shift 2
                ;;
            --timeout-seconds)
                [[ $# -ge 2 ]] || { echo "--timeout-seconds requires a value" >&2; exit 1; }
                TIMEOUT_SECONDS="$2"
                shift 2
                ;;
            --poll-seconds)
                [[ $# -ge 2 ]] || { echo "--poll-seconds requires a value" >&2; exit 1; }
                POLL_SECONDS="$2"
                shift 2
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                echo "Unknown argument: $1" >&2
                exit 1
                ;;
        esac
    done

    [[ -n "$STANDALONE_RUN_DIR" ]] || { echo "--standalone-run-dir is required" >&2; exit 1; }
}

log() {
    printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}

setup_run_dir() {
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    RUN_DIR="$REPO_ROOT/output/lume-pr-validation/$ts"
    mkdir -p "$RUN_DIR"
    ln -sfn "$RUN_DIR" "$REPO_ROOT/output/lume-pr-validation/latest"
}

copy_if_exists() {
    local src="$1"
    local dest="$2"
    if [[ -e "$src" ]]; then
        cp -R "$src" "$dest"
    fi
}

wait_for_standalone_completion() {
    local started now
    started="$(date +%s)"
    while true; do
        if [[ -f "$STANDALONE_RUN_DIR/summary.md" ]]; then
            return 0
        fi
        now="$(date +%s)"
        if (( now - started > TIMEOUT_SECONDS )); then
            MESSAGE="Timed out waiting for standalone validation to finish."
            return 1
        fi
        sleep "$POLL_SECONDS"
    done
}

standalone_passed() {
    grep -q "Outcome: passed" "$STANDALONE_RUN_DIR/summary.md"
}

run_and_log() {
    local name="$1"
    shift
    log "Running $name"
    if "$@" >"$RUN_DIR/$name.log" 2>&1; then
        echo "passed" >"$RUN_DIR/$name.status"
        return 0
    fi
    echo "failed" >"$RUN_DIR/$name.status"
    return 1
}

write_summary() {
    cat >"$RUN_DIR/summary.md" <<EOF
# Lume PR Validation

- Status: $STATUS
- Message: ${MESSAGE:-Validation completed.}
- Standalone run dir: $STANDALONE_RUN_DIR
- Standalone summary: $STANDALONE_RUN_DIR/summary.md
- Evidence directory: $RUN_DIR

## Step Results

EOF

    local step
    for step in build-ghosttykit swift-build swift-tests dev-smoke ui-smoke host-preflight host-smoke; do
        if [[ -f "$RUN_DIR/$step.status" ]]; then
            printf -- "- %s: %s\n" "$step" "$(cat "$RUN_DIR/$step.status")" >>"$RUN_DIR/summary.md"
            printf -- "  log: %s/%s.log\n" "$RUN_DIR" "$step" >>"$RUN_DIR/summary.md"
        fi
    done
}

step_passed() {
    local step="$1"
    [[ -f "$RUN_DIR/$step.status" ]] && [[ "$(cat "$RUN_DIR/$step.status")" == "passed" ]]
}

evaluate_status() {
    local step
    local required_failures=()
    local optional_failures=()

    for step in "${REQUIRED_STEPS[@]}"; do
        if ! step_passed "$step"; then
            required_failures+=("$step")
        fi
    done

    for step in "${OPTIONAL_STEPS[@]}"; do
        if ! step_passed "$step"; then
            optional_failures+=("$step")
        fi
    done

    if (( ${#required_failures[@]} > 0 )); then
        STATUS="failed"
        MESSAGE="Required validation steps failed: ${required_failures[*]}"
        if (( ${#optional_failures[@]} > 0 )); then
            MESSAGE+=". Optional step failures: ${optional_failures[*]}"
        fi
        return 1
    fi

    STATUS="passed"
    if (( ${#optional_failures[@]} > 0 )); then
        MESSAGE="Required validation steps passed. Optional step failures: ${optional_failures[*]}"
    else
        MESSAGE="Standalone and app-level Lume validation passed."
    fi
    return 0
}

main() {
    parse_args "$@"
    setup_run_dir

    copy_if_exists "$STANDALONE_RUN_DIR/summary.md" "$RUN_DIR/standalone-summary.md"
    copy_if_exists "$STANDALONE_RUN_DIR/status.json" "$RUN_DIR/standalone-status.json"

    if ! wait_for_standalone_completion; then
        STATUS="failed"
        write_summary
        exit 1
    fi

    copy_if_exists "$STANDALONE_RUN_DIR/summary.md" "$RUN_DIR/standalone-summary.md"
    copy_if_exists "$STANDALONE_RUN_DIR/status.json" "$RUN_DIR/standalone-status.json"

    if ! standalone_passed; then
        STATUS="blocked"
        MESSAGE="Standalone validation did not pass; downstream app validation is intentionally blocked."
        write_summary
        exit 1
    fi

    pushd "$REPO_ROOT" >/dev/null
    run_and_log build-ghosttykit ./scripts/build-ghosttykit.sh || true
    run_and_log swift-build swift build || true
    run_and_log swift-tests swift test --filter 'LumeValidatedBaseServiceTests|LumeRuntimeServiceTests|HostLumeSmokeAutomationTests|ModelsTests|WorkspaceProviderTests|WorkspaceProviderSetupCoordinatorTests' || true
    run_and_log dev-smoke ./scripts/dev-smoke.sh --no-build || true
    run_and_log ui-smoke ./scripts/ui-smoke.sh || true
    run_and_log host-preflight ./scripts/lume-host-preflight.sh --no-build || true
    run_and_log host-smoke ./scripts/lume-host-macos-smoke.sh --skip-preflight --timeout-seconds 5400 || true
    popd >/dev/null

    if evaluate_status; then
        write_summary
        return 0
    fi

    write_summary
    return 1
}

main "$@"
