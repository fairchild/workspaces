#!/bin/bash
# Verify packaged-app performance and resource packaging for release signoff.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  ./scripts/verify-installed-perf.sh [--allow-skip-noninteractive] <WorkSpaces.app|binary> [output_dir]

Checks:
  - bundled Ghostty resources exist
  - bundled terminfo exists
  - installed clean-shell capture emits terminal_first_output and first_prompt_ready
  - log does not contain known Ghostty resource packaging warnings
EOF
}

fail() {
    echo "[verify-installed-perf] ERROR: $*" >&2
    exit 1
}

write_status() {
    local status="$1"
    local reason="$2"
    local status_file="${OUTPUT_DIR:-}/verification-status.json"
    [[ -n "${OUTPUT_DIR:-}" ]] || return 0
    cat >"$status_file" <<EOF
{
  "status": "$status",
  "reason": "$reason",
  "app_bundle": "${APP_BUNDLE:-}",
  "app_binary": "${APP_BINARY:-}",
  "log_file": "${LOG_FILE:-}",
  "summary_json": "${SUMMARY_JSON:-}",
  "summary_txt": "${SUMMARY_TXT:-}"
}
EOF
}

skip_noninteractive() {
    local reason="$1"
    write_status "skipped_noninteractive_display" "$reason"
    echo "[verify-installed-perf] WARNING: $reason" >&2
    echo "[verify-installed-perf] status: skipped_noninteractive_display" >&2
    exit 0
}

ALLOW_SKIP_NONINTERACTIVE=0

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ "${1:-}" == "--allow-skip-noninteractive" ]]; then
    ALLOW_SKIP_NONINTERACTIVE=1
    shift
fi

[[ $# -ge 1 ]] || {
    usage
    exit 1
}

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$1"
OUTPUT_DIR="${2:-/tmp/workspaces-installed-perf-verify-$(date +%Y%m%d-%H%M%S)}"

if [[ -d "$TARGET" ]]; then
    APP_BUNDLE="$TARGET"
    APP_BINARY="$APP_BUNDLE/Contents/MacOS/WorkspaceManager"
else
    APP_BINARY="$TARGET"
    APP_BUNDLE="$(cd "$(dirname "$APP_BINARY")/../.." && pwd)"
fi

[[ -x "$APP_BINARY" ]] || fail "App binary not found: $APP_BINARY"
[[ -d "$APP_BUNDLE" ]] || fail "App bundle not found: $APP_BUNDLE"

mkdir -p "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/app-data"

[[ -d "$APP_BUNDLE/Contents/Resources/ghostty" ]] || fail "Missing Ghostty resources directory"
[[ -d "$APP_BUNDLE/Contents/Resources/terminfo" ]] || fail "Missing bundled terminfo directory"

LOG_FILE="$OUTPUT_DIR/installed-clean.log"
SUMMARY_JSON="$OUTPUT_DIR/installed-clean-summary.json"
SUMMARY_TXT="$OUTPUT_DIR/installed-clean-summary.txt"

WORKSPACES_DATA_DIR="$OUTPUT_DIR/app-data" "$ROOT_DIR/scripts/launch-installed-diagnostics.sh" \
    --app "$APP_BINARY" \
    --clean-shell \
    --no-activate \
    --capture-seconds 12 \
    --log-file "$LOG_FILE"

"$ROOT_DIR/.agents/skills/workspaces-optimization/scripts/summarize_perf_log.py" \
    --json \
    --scenario installed_clean_shell \
    --build-kind installed \
    --app-path "$APP_BINARY" \
    "$LOG_FILE" >"$SUMMARY_JSON"

"$ROOT_DIR/.agents/skills/workspaces-optimization/scripts/summarize_perf_log.py" \
    --scenario installed_clean_shell \
    --build-kind installed \
    --app-path "$APP_BINARY" \
    "$LOG_FILE" >"$SUMMARY_TXT"

if rg -n "ghostty terminfo not found|no resources dir set, shell integration disabled" "$LOG_FILE" >/dev/null; then
    fail "Detected Ghostty resource packaging warnings in $LOG_FILE"
fi

if rg -n "CVDisplayLinkCreateWithCGDisplays error -6661|embedded_window: error initializing surface err=error.OutOfMemory" "$LOG_FILE" >/dev/null; then
    if [[ "$ALLOW_SKIP_NONINTERACTIVE" -eq 1 ]]; then
        skip_noninteractive "Installed-build perf verification requires an interactive display-capable macOS session; Ghostty surface initialization failed in the current environment"
    fi
    fail "Installed-build perf verification requires an interactive display-capable macOS session; Ghostty surface initialization failed in the current environment"
fi

# Apps launched in CI go into .accessory policy (no foreground activation),
# so the terminal never becomes key and first_prompt_ready never fires. The
# terminal surface itself is healthy — this is a foreground-session
# limitation of the runner, not a perf regression.
if rg -n "CI detected: \.accessory policy" "$LOG_FILE" >/dev/null \
   && [[ "$ALLOW_SKIP_NONINTERACTIVE" -eq 1 ]]; then
    skip_noninteractive "Installed-build perf verification requires a foreground GUI session; runner launched the app under .accessory policy"
fi

python3 - "$SUMMARY_JSON" <<'PY'
import json
import sys
from pathlib import Path

summary = json.loads(Path(sys.argv[1]).read_text())
metrics = summary.get("metrics", {})
missing = [
    metric
    for metric in ("terminal_first_output", "first_prompt_ready")
    if metric not in metrics
]
if missing:
    raise SystemExit(f"missing installed perf metrics: {', '.join(missing)}")
PY

write_status "verified" "installed clean-shell metrics present"
echo "Verified installed perf parity for $APP_BUNDLE"
echo "  log: $LOG_FILE"
echo "  summary_json: $SUMMARY_JSON"
echo "  summary_txt: $SUMMARY_TXT"
