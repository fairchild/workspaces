#!/bin/bash
# Launch the installed WorkSpaces app with diagnostics-friendly env vars.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  ./scripts/launch-installed-diagnostics.sh [options]

Options:
  --app <path>           Installed app binary path.
  --log-file <path>      Path to write combined stdout/stderr.
  --clean-shell          Launch embedded terminals with clean shell profiles.
  --login-shell          Launch embedded terminals with normal login profiles.
  --capture-seconds <n>  Auto-terminate the app after n seconds and keep the log.
  --with-input-diagnostics
                         Enable per-key input diagnostics. Use only for short captures.
  --no-activate          Do not activate the app on launch.
  --keep-auto-import     Do not disable repo auto-import.
  -h, --help             Show this help text.

Defaults:
  - enables focus and terminal diagnostics
  - leaves input diagnostics off unless explicitly requested
  - disables repo auto-import to reduce unrelated startup noise
  - launches the installed app at:
    /Applications/WorkSpaces.app/Contents/MacOS/WorkspaceManager
EOF
}

APP_PATH="/Applications/WorkSpaces.app/Contents/MacOS/WorkspaceManager"
LOG_FILE="/tmp/workspaces-installed-diagnostics-$(date +%Y%m%d-%H%M%S).log"
SHELL_MODE=""
NO_ACTIVATE=0
DISABLE_AUTO_IMPORT=1
WITH_INPUT_DIAGNOSTICS=0
CAPTURE_SECONDS=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)
            APP_PATH="$2"
            shift 2
            ;;
        --log-file)
            LOG_FILE="$2"
            shift 2
            ;;
        --clean-shell)
            SHELL_MODE="clean"
            shift
            ;;
        --login-shell)
            SHELL_MODE="login"
            shift
            ;;
        --with-input-diagnostics)
            WITH_INPUT_DIAGNOSTICS=1
            shift
            ;;
        --capture-seconds)
            CAPTURE_SECONDS="$2"
            shift 2
            ;;
        --no-activate)
            NO_ACTIVATE=1
            shift
            ;;
        --keep-auto-import)
            DISABLE_AUTO_IMPORT=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unexpected argument: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ ! -x "$APP_PATH" ]]; then
    echo "Installed app binary not found or not executable: $APP_PATH" >&2
    exit 1
fi

ENV_VARS=(
    "WORKSPACES_FOCUS_DIAGNOSTICS=1"
    "WORKSPACES_TERMINAL_DIAGNOSTICS=1"
    "WORKSPACES_DISABLE_STATE_RESTORATION=1"
)
APP_ARGS=(
    "-ApplePersistenceIgnoreState"
    "YES"
)

if [[ "$WITH_INPUT_DIAGNOSTICS" -eq 1 ]]; then
    ENV_VARS+=("WORKSPACES_INPUT_DIAGNOSTICS=detailed")
fi

if [[ -n "$SHELL_MODE" ]]; then
    ENV_VARS+=("WORKSPACES_SHELL_PROFILE_MODE=$SHELL_MODE")
fi

if [[ "$NO_ACTIVATE" -eq 1 ]]; then
    ENV_VARS+=("WORKSPACES_NO_ACTIVATE_ON_LAUNCH=1")
fi

if [[ "$DISABLE_AUTO_IMPORT" -eq 1 ]]; then
    ENV_VARS+=("WORKSPACES_DISABLE_AUTO_IMPORT=1")
fi

echo "Launching installed diagnostics build"
echo "  app: $APP_PATH"
echo "  log: $LOG_FILE"
echo "  env:"
for entry in "${ENV_VARS[@]}"; do
    echo "    $entry"
done
echo "  summarize:"
echo "    ./.agents/skills/workspaces-optimization/scripts/summarize_perf_log.py $LOG_FILE"
echo "  app_args:"
for entry in "${APP_ARGS[@]}"; do
    echo "    $entry"
done
if [[ "$CAPTURE_SECONDS" -gt 0 ]]; then
    echo "  capture_seconds: $CAPTURE_SECONDS"
    env "${ENV_VARS[@]}" "$APP_PATH" "${APP_ARGS[@]}" > >(tee "$LOG_FILE") 2>&1 &
    APP_PID=$!
    sleep "$CAPTURE_SECONDS"
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
else
    env "${ENV_VARS[@]}" "$APP_PATH" "${APP_ARGS[@]}" 2>&1 | tee "$LOG_FILE"
fi
