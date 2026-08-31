#!/bin/bash
# Launch the installed WorkSpaces app with diagnostics-friendly env vars.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/perf-process.sh"

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

# UserDefaults is the axis that decides what this launch does. #1252 identified it and
# #1258 made it switchable, but the wiring landed in perf-baseline.sh only — this lane
# kept running against `domain=standard`, the developer's own preferences. It therefore
# restored their live workspaces and measured a restore that reattaches long-lived tmux
# sessions, which emit no readiness signal, so `launch_to_first_prompt` never closed at
# all: 3/3 captures recorded nothing while the app was healthy. With the domain pinned,
# the same lane and the same build measure 144.57 ms (#1462).
#
# A caller-provided suite belongs to the caller and is never reset or removed here,
# matching perf-baseline.sh's contract.
if [[ -n "${WORKSPACES_PREFERENCES_SUITE:-}" ]]; then
    PERF_PREFERENCES_SUITE="$WORKSPACES_PREFERENCES_SUITE"
    PERF_PREFERENCES_SUITE_OWNER="caller"
else
    PERF_PREFERENCES_SUITE="com.cloudcompute.workspaces.installed-perf.$$-$(date +%Y%m%d%H%M%S)"
    PERF_PREFERENCES_SUITE_OWNER="lane"
    defaults delete "$PERF_PREFERENCES_SUITE" >/dev/null 2>&1 || true
fi

# The tmux server is cross-run state neither the data dir nor the preferences suite
# covers. It is not what broke the capture above — a pinned domain fixes that on its
# own — but an isolated run creating sessions on the desktop's server still leaves
# litter behind, so the lane names its own.
PERF_TMUX_SOCKET_LABEL="${WORKSPACES_TMUX_SOCKET_LABEL:-workspaces-perf-$$-$(date +%s)}"

ENV_VARS=(
    "WORKSPACES_FOCUS_DIAGNOSTICS=1"
    "WORKSPACES_TERMINAL_DIAGNOSTICS=1"
    "WORKSPACES_DISABLE_STATE_RESTORATION=1"
    "WORKSPACES_PREFERENCES_SUITE=$PERF_PREFERENCES_SUITE"
    "WORKSPACES_TMUX_SOCKET_LABEL=$PERF_TMUX_SOCKET_LABEL"
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
# App logging is os.Logger, which writes to the unified log rather than
# stdout/stderr — including the `[Perf]` metric lines summarize_perf_log.py
# reads. Appending the subsystem's entries keeps the captured log complete for
# consumers that only see this file.
append_unified_log() {
    local since="$1" pid="${2:-}"
    # Scope to the pid this run launched. The subsystem is shared by every build of
    # the app, and the no-instance guard is deliberately path-anchored so it never
    # touches an app it does not own — which means another WorkSpaces binary (the
    # /Applications copy, a debug build) can be running legitimately and emit its own
    # [Perf] lines into this window. The summarizer does not scope by process, so an
    # unscoped capture would average a foreign launch into this one's numbers.
    local predicate='subsystem == "com.cloudcompute.workspaces"'
    if [[ -n "$pid" ]]; then
        predicate="$predicate AND processIdentifier == $pid"
    fi
    log show \
        --info \
        --start "$since" \
        --predicate "$predicate" \
        --style compact >>"$LOG_FILE" 2>/dev/null || true
}

CAPTURE_START="$(date '+%Y-%m-%d %H:%M:%S')"

if [[ "$CAPTURE_SECONDS" -gt 0 ]]; then
    echo "  capture_seconds: $CAPTURE_SECONDS"
    perf_assert_no_instance "$APP_PATH" "$(basename "$0")"
    env "${ENV_VARS[@]}" "$APP_PATH" "${APP_ARGS[@]}" > >(tee "$LOG_FILE") 2>&1 &
    APP_PID=$!
    sleep "$CAPTURE_SECONDS"
    perf_stop_launched_app "$APP_PID" || {
        echo "the launched app survived SIGKILL (pid $APP_PID)" >&2
        exit 1
    }
    # `wait` only after the pid is confirmed gone: against an app that ignores
    # SIGTERM it blocks forever, and the interrupt that ends that wait is what
    # leaves the instance behind.
    wait "$APP_PID" 2>/dev/null || true
    perf_assert_clean_exit "$APP_PATH" "$(basename "$0")"
    append_unified_log "$CAPTURE_START" "$APP_PID"
    # Only a server this invocation invented: a caller-supplied label belongs to the
    # caller, exactly as the preferences suite does.
    if [[ -z "${WORKSPACES_TMUX_SOCKET_LABEL:-}" ]]; then
        tmux -L "$PERF_TMUX_SOCKET_LABEL" kill-server >/dev/null 2>&1 || true
    fi
    if [[ "$PERF_PREFERENCES_SUITE_OWNER" == "lane" ]]; then
        defaults delete "$PERF_PREFERENCES_SUITE" >/dev/null 2>&1 || true
        rm -f "$HOME/Library/Preferences/$PERF_PREFERENCES_SUITE.plist"
    fi
else
    env "${ENV_VARS[@]}" "$APP_PATH" "${APP_ARGS[@]}" 2>&1 | tee "$LOG_FILE"
    append_unified_log "$CAPTURE_START"
fi
