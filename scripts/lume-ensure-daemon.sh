#!/bin/bash
# ==========================================================================
# lume-ensure-daemon.sh - Ensure the Lume daemon is running and reachable
# ==========================================================================
#
# Idempotent: safe to call from cron, mise tasks, CI pre-steps, or manually.
# Checks daemon health, loads LaunchAgent if needed, starts daemon if missing.
#
# Exit codes:
#   0 - daemon is reachable
#   1 - daemon could not be started after all recovery attempts
#
# Environment:
#   LUME_PORT            - daemon port (default: 7777)
#   LUME_HEALTH_TIMEOUT  - curl timeout in seconds (default: 3)
#   LUME_STARTUP_WAIT    - seconds to wait for daemon after starting (default: 15)
#   LUME_QUIET           - set to 1 to suppress non-error output

set -euo pipefail

PORT="${LUME_PORT:-7777}"
HEALTH_TIMEOUT="${LUME_HEALTH_TIMEOUT:-3}"
STARTUP_WAIT="${LUME_STARTUP_WAIT:-15}"
QUIET="${LUME_QUIET:-0}"

LAUNCH_AGENT_LABEL="com.trycua.lume_daemon"
LAUNCH_AGENT_PLIST="$HOME/Library/LaunchAgents/${LAUNCH_AGENT_LABEL}.plist"
LUME_APP_BIN="$HOME/.local/share/lume/lume.app/Contents/MacOS/lume"
LUME_BIN="${LUME_BIN:-$HOME/.local/bin/lume}"

log() {
    [[ "$QUIET" == "1" ]] && return
    echo "[lume-ensure] $(date +%H:%M:%S) $*"
}

err() {
    echo "[lume-ensure] ERROR: $*" >&2
}

daemon_healthy() {
    /usr/bin/curl --silent --fail --max-time "$HEALTH_TIMEOUT" \
        "http://127.0.0.1:${PORT}/lume/host/status" >/dev/null 2>&1
}

wait_for_daemon() {
    local elapsed=0
    while (( elapsed < STARTUP_WAIT )); do
        if daemon_healthy; then
            return 0
        fi
        sleep 1
        (( elapsed++ ))
    done
    return 1
}

resolve_lume_bin() {
    if [[ -x "$LUME_APP_BIN" ]]; then
        echo "$LUME_APP_BIN"
    elif [[ -x "$LUME_BIN" ]]; then
        echo "$LUME_BIN"
    elif command -v lume >/dev/null 2>&1; then
        command -v lume
    else
        return 1
    fi
}

# --- Fast path: already healthy ---
if daemon_healthy; then
    log "daemon healthy on port $PORT"
    exit 0
fi

log "daemon not responding on port $PORT, attempting recovery..."

# --- Attempt 1: load existing LaunchAgent ---
if [[ -f "$LAUNCH_AGENT_PLIST" ]]; then
    log "LaunchAgent plist exists, loading..."
    launchctl load "$LAUNCH_AGENT_PLIST" 2>/dev/null || true
    if wait_for_daemon; then
        log "daemon recovered via LaunchAgent"
        exit 0
    fi
    log "LaunchAgent load did not bring daemon up"
fi

# --- Attempt 2: create LaunchAgent if missing, then load ---
if [[ ! -f "$LAUNCH_AGENT_PLIST" ]]; then
    LUME_SERVE_BIN="$(resolve_lume_bin)" || {
        err "no lume binary found — install lume first"
        exit 1
    }
    log "creating LaunchAgent plist at $LAUNCH_AGENT_PLIST"
    mkdir -p "$(dirname "$LAUNCH_AGENT_PLIST")"
    cat > "$LAUNCH_AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LAUNCH_AGENT_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${LUME_SERVE_BIN}</string>
        <string>serve</string>
        <string>--port</string>
        <string>${PORT}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/lume_daemon.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/lume_daemon.error.log</string>
</dict>
</plist>
PLIST

    launchctl load "$LAUNCH_AGENT_PLIST" 2>/dev/null || true
    if wait_for_daemon; then
        log "daemon started via new LaunchAgent"
        exit 0
    fi
    log "LaunchAgent creation + load did not bring daemon up"
fi

# --- Attempt 3: direct start as fallback ---
LUME_SERVE_BIN="$(resolve_lume_bin)" || {
    err "no lume binary found — install lume first"
    exit 1
}
log "starting daemon directly: $LUME_SERVE_BIN serve --port $PORT"
nohup "$LUME_SERVE_BIN" serve --port "$PORT" \
    > /tmp/lume_daemon.log 2> /tmp/lume_daemon.error.log &

if wait_for_daemon; then
    log "daemon started directly (not managed by launchd)"
    exit 0
fi

err "daemon failed to start after all recovery attempts"
err "check /tmp/lume_daemon.log and /tmp/lume_daemon.error.log"
exit 1
