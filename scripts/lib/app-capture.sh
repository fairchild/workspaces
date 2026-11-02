#!/bin/bash
# Headless-safe self-capture of the WorkSpaces app for the evidence lane.
#
# Launches the debug build in a named fixture state with the Automation API and
# operator scope enabled and no activation, waits for that app to report its
# per-launch operator credential (the natural readiness signal), snapshots the
# main window through the `workspaces window snapshot` CLI (CGWindowList, TCC-free,
# no focus steal), and stops the launched app. The result is a full-fidelity PNG
# — sidebar chrome and the GhosttyKit terminal surface — captured with zero
# desktop disruption, so it works with the screen backgrounded on a shared desktop.
#
# Requires REPO_ROOT to be set by the caller, and scripts/lib/fixture-scenarios.sh
# to be sourced first. Every failure path returns a clear message and non-zero
# rather than hanging; readiness waits are bounded.

# WORKSPACES_SYNTHETIC_ROOT moves the launched app's automation socket and operator
# credential to a directory of their own (AutomationSupportDirectory), and the
# `workspaces` CLI resolves that directory the same way the app does. The lane reaches
# operator scope only through the CLI with the root exported, so it names no credential
# path and removes no file: the real Application Support path holds the installed
# app's live credential, and a bash copy of the resolver is what drifted in #1427.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=synthetic-root.sh
source "$LIB_DIR/synthetic-root.sh"
# shellcheck source=build-products.sh
source "$LIB_DIR/build-products.sh"

APP_CAPTURE_PID=""
APP_CAPTURE_LAUNCHED=""
APP_CAPTURE_PRODUCTS_DIR=""

# Runs before anything reads the two paths below, in the lane's own shell: their callers
# are command substitutions, which could not keep the answer for the next call.
app_capture_resolve_products() {
    [[ -n "$APP_CAPTURE_PRODUCTS_DIR" ]] && return 0
    APP_CAPTURE_PRODUCTS_DIR="$(build_products_dir "$REPO_ROOT")"
}

app_capture_debug_binary() {
    printf '%s/WorkspaceManager' "$APP_CAPTURE_PRODUCTS_DIR"
}

app_capture_cli_binary() {
    printf '%s/workspaces' "$APP_CAPTURE_PRODUCTS_DIR"
}

# app_capture_debug_binary_pattern — the debug binary path as a `pgrep -f`/`pkill -f`
# regex that matches only the literal path. `-f` treats its argument as a regex, so
# the unescaped `.` in `.build` would match any character and could bind a sibling
# process; escaping the dots anchors the match to our exact binary.
app_capture_debug_binary_pattern() {
    local path
    path="$(app_capture_debug_binary)"
    printf '%s' "${path//./\\.}"
}

# app_capture_png_has_content <png> — exit 0 if the PNG carries rendered content,
# non-zero if it is (near-)uniform blank. The operator credential proves the API is
# up, not that the window painted its first frame, so a snapshot fired too early
# captures a blank white pre-composite frame. This downsamples to 32x32 and checks
# the luminance spread: a real frame (dark terminal surface + light chrome) spreads
# wide; a blank frame is flat. Uses ImageIO only — no extra dependency.
app_capture_png_has_content() {
    swift - "$1" <<'SWIFT'
import CoreGraphics
import Foundation
import ImageIO

guard CommandLine.arguments.count > 1 else { exit(2) }
let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
    let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
else { exit(2) }
let w = 32, h = 32
let cs = CGColorSpaceCreateDeviceRGB()
var buf = [UInt8](repeating: 0, count: w * h * 4)
guard
    let ctx = CGContext(
        data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { exit(2) }
ctx.interpolationQuality = .low
ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
var minV = 255, maxV = 0
for i in stride(from: 0, to: buf.count, by: 4) {
    let lum = (Int(buf[i]) * 30 + Int(buf[i + 1]) * 59 + Int(buf[i + 2]) * 11) / 100
    if lum < minV { minV = lum }
    if lum > maxV { maxV = lum }
}
exit((maxV - minV) >= 24 ? 0 : 1)  // exit 0 == rendered content
SWIFT
}

# app_capture_operator_state — print "<pid> <operatorCredential>" from whichever app
# answers the automation socket this lane's environment resolves to. Prints nothing and
# returns non-zero until a listener is up.
app_capture_operator_state() {
    "$(app_capture_cli_binary)" automation health --json 2>/dev/null | python3 -c '
import json, sys
server = json.load(sys.stdin).get("server") or {}
print(server.get("pid", ""), server.get("operatorCredential", ""))
' 2>/dev/null
}

# app_capture_stop — stop the launched debug app.
# Idempotent; safe to wire to an EXIT trap so the app never outlives the lane.
# No-op until a launch was actually attempted, so a pre-launch validation
# failure never kills an unrelated dev instance of the same binary.
app_capture_stop() {
    [[ -n "$APP_CAPTURE_LAUNCHED" ]] || return 0
    if [[ -n "$APP_CAPTURE_PID" ]] && kill -0 "$APP_CAPTURE_PID" 2>/dev/null; then
        kill "$APP_CAPTURE_PID" 2>/dev/null || true
    fi
    # Fallback for a launch that started the app but failed before we captured its
    # pid: match only our exact (regex-escaped) debug binary path — never a sibling.
    pkill -f "$(app_capture_debug_binary_pattern)" 2>/dev/null || true
    APP_CAPTURE_PID=""
}

# app_capture_window <out_png> <scenario-or-inline> [timeout_seconds]
# Produces a PNG at <out_png>. Progress and errors go to stderr.
app_capture_window() {
    local out_png="$1"
    local scenario="$2"
    local timeout_seconds="${3:-45}"

    app_capture_resolve_products || return 1

    local debug_binary cli_binary data_dir
    debug_binary="$(app_capture_debug_binary)"
    cli_binary="$(app_capture_cli_binary)"
    data_dir="$REPO_ROOT/.dev-data/evidence-lane"

    if [[ ! -x "$debug_binary" ]]; then
        echo "error: debug app binary not found at $debug_binary — run 'swift build' first (or drop --no-build)." >&2
        return 1
    fi
    if [[ ! -x "$cli_binary" ]]; then
        echo "error: 'workspaces' CLI not found at $cli_binary — run 'swift build' first (or drop --no-build)." >&2
        return 1
    fi

    if ! fixture_resolve_scenario "$scenario"; then
        echo "error: unknown fixture scenario '$scenario'." >&2
        echo "       Known: $(fixture_scenario_names | paste -sd, -), or inline:<agent-states>." >&2
        return 1
    fi

    # Isolation boundary: point the app's workspaces root inside the evidence-lane
    # data dir so the launch-time orphan scan reads a deterministic (empty) root
    # instead of the owner's real ~/workspaces, and exporting the root gives the app
    # and every CLI call below one private automation directory. --clean-data wipes
    # the root each run; the app recreates it on launch.
    synthetic_root_ensure "$data_dir/workspaces-root" || return 1
    synthetic_root_require || return 1

    # A WorkSpaces terminal exports these for the installed app that owns it, and the
    # CLI's socket verbs prefer them over the root, so a capture driven from a tile
    # would otherwise ask that app whether it is ready.
    unset WORKSPACES_AUTOMATION_SOCKET WORKSPACES_AUTOMATION_HANDLE

    # --coexist: an evidence capture must never kill the operator's installed
    # WorkSpaces.app (or the terminal session driving the capture); only a stale
    # debug instance is replaced. Harmless on CI, where no installed app exists.
    local -a launch_args=(
        --no-build --no-activate --fixture --clean-data --coexist
        --data-dir "$data_dir"
        --env "WORKSPACES_SYNTHETIC_ROOT=$WORKSPACES_SYNTHETIC_ROOT"
        --env WORKSPACES_AUTOMATION_API=1
        --env WORKSPACES_AUTOMATION_OPERATOR=1
    )
    [[ -n "$FIXTURE_AGENT_STATES" ]] \
        && launch_args+=(--env "WORKSPACES_UI_FIXTURE_AGENT_STATES=$FIXTURE_AGENT_STATES")
    [[ -n "$FIXTURE_COMMAND_STATUSES" ]] \
        && launch_args+=(--env "WORKSPACES_UI_FIXTURE_COMMAND_STATUSES=$FIXTURE_COMMAND_STATUSES")
    [[ -n "$FIXTURE_FILE_TREE_FAILURE" ]] \
        && launch_args+=(--env "WORKSPACES_UI_FIXTURE_FILE_TREE_FAILURE=$FIXTURE_FILE_TREE_FAILURE")
    [[ -n "$FIXTURE_SIDEBAR_ARRANGEMENT" ]] \
        && launch_args+=(--env "WORKSPACES_UI_FIXTURE_SIDEBAR_ARRANGEMENT=$FIXTURE_SIDEBAR_ARRANGEMENT")
    [[ -n "$FIXTURE_CMD_T_REPO" ]] \
        && launch_args+=(--env "WORKSPACES_UI_FIXTURE_CMD_T_REPO=$FIXTURE_CMD_T_REPO")
    [[ -n "$FIXTURE_TRIGGER_CMD_T" ]] \
        && launch_args+=(--env "WORKSPACES_UI_FIXTURE_TRIGGER_CMD_T=$FIXTURE_TRIGGER_CMD_T")
    [[ -n "$FIXTURE_PINNED" ]] \
        && launch_args+=(--env "WORKSPACES_UI_FIXTURE_PINNED=$FIXTURE_PINNED")
    [[ -n "$FIXTURE_ARCHIVED" ]] \
        && launch_args+=(--env "WORKSPACES_UI_FIXTURE_ARCHIVED=$FIXTURE_ARCHIVED")
    [[ -n "$FIXTURE_SELECTED" ]] \
        && launch_args+=(--env "WORKSPACES_UI_FIXTURE_SELECTED=$FIXTURE_SELECTED")
    if [[ -n "$FIXTURE_SEED_RESTORE_BANNER" ]]; then
        # The seed alone is inert — the restore banner is gated behind the
        # restoreSessionsOnLaunch experiment, force-enabled here so the scenario
        # is self-contained (no separate flag for the caller to remember).
        launch_args+=(--env "WORKSPACES_UI_FIXTURE_SEED_RESTORE_BANNER=1")
        launch_args+=(--env WORKSPACES_RESTORE_SESSIONS_ON_LAUNCH=1)
    fi

    echo "→ launching debug app (fixture=$scenario, operator scope, no-activate)…" >&2
    APP_CAPTURE_LAUNCHED=1
    local launch_output
    if ! launch_output="$("$REPO_ROOT/scripts/launch-dev.sh" "${launch_args[@]}" 2>&1 | tee /dev/stderr)"; then
        echo "error: app failed to launch; inspect the latest .dev-data/logs/launch-diagnostics-* bundle." >&2
        return 1
    fi
    APP_CAPTURE_PID="$(printf '%s\n' "$launch_output" | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | tail -n 1)"
    if [[ -z "$APP_CAPTURE_PID" ]]; then
        echo "error: could not determine the launched app's pid from launch-dev.sh output." >&2
        return 1
    fi

    # Readiness asks the running listener rather than watching for a file, so a
    # credential left by an earlier run cannot pass for this launch's, and comparing
    # pids fails the lane when anything but this launch answers the socket.
    echo "→ waiting up to ${timeout_seconds}s for operator credential (readiness)…" >&2
    local waited=0 state listener_pid credential
    while :; do
        state="$(app_capture_operator_state)" || state=""
        read -r listener_pid credential <<<"$state" || true
        if [[ -n "$listener_pid" && "$listener_pid" != "$APP_CAPTURE_PID" ]]; then
            echo "error: pid $listener_pid answered the automation socket, and this lane launched pid $APP_CAPTURE_PID." >&2
            echo "       A snapshot here would capture another app (root: $WORKSPACES_SYNTHETIC_ROOT)." >&2
            return 1
        fi
        case "$credential" in
            minted|reused) break ;;
            not_opted_in|mint_failed)
                echo "error: the launched app reported operatorCredential=$credential." >&2
                echo "       The launch must enable operator scope (WORKSPACES_AUTOMATION_API=1 and" >&2
                echo "       WORKSPACES_AUTOMATION_OPERATOR=1) — check .dev-data/logs for launch failures." >&2
                return 1
                ;;
        esac
        if ! kill -0 "$APP_CAPTURE_PID" 2>/dev/null; then
            echo "error: app exited before operator scope became ready." >&2
            return 1
        fi
        if (( waited >= timeout_seconds )); then
            echo "error: operator scope did not become ready within ${timeout_seconds}s (last health: ${state:-no listener})." >&2
            echo "       The launch must enable operator scope (WORKSPACES_AUTOMATION_API=1 and" >&2
            echo "       WORKSPACES_AUTOMATION_OPERATOR=1) — check .dev-data/logs for launch failures." >&2
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done

    # Snapshot, then gate on rendered content. The credential appears the moment
    # the automation listener is up, which can precede the window painting its first
    # frame — so a single snapshot can capture a blank pre-composite frame. Retry
    # until the PNG carries real pixels, bounded by a deadline (no fixed sleep alone).
    echo "→ snapshotting main window via operator scope (retry until content composited)…" >&2
    local content_deadline=$(( timeout_seconds > 20 ? timeout_seconds : 20 ))
    local content_waited=0
    while :; do
        if ! "$cli_binary" window snapshot --out "$out_png" >&2; then
            echo "error: window snapshot failed (see the CLI message above)." >&2
            return 1
        fi
        if [[ ! -f "$out_png" ]]; then
            echo "error: snapshot reported success but no PNG was written to $out_png." >&2
            return 1
        fi
        if app_capture_png_has_content "$out_png"; then
            break
        fi
        if (( content_waited >= content_deadline )); then
            echo "error: window never rendered non-blank content within ${content_deadline}s" >&2
            echo "       (every snapshot came back blank — the window is up but not painting)." >&2
            return 1
        fi
        echo "  · blank frame; window still compositing, retrying…" >&2
        sleep 1
        content_waited=$((content_waited + 1))
    done

    if [[ -n "$FIXTURE_SEED_RESTORE_BANNER" ]]; then
        # Non-blank content proves the base window painted, not that the restore banner
        # specifically has — computeRestorePlanIfEnabled() (which decides that) runs later
        # in the same launch sequence and can still be in flight when the base chrome first
        # composites. There's no readiness signal for "restore plan decided" to poll, so this
        # is a heuristic settle, not a guarantee: give it a fixed margin, then re-snapshot.
        echo "→ restore-banner scenario: settling before final snapshot (banner decision can lag first paint)…" >&2
        sleep 2
        if ! "$cli_binary" window snapshot --out "$out_png" >&2; then
            echo "error: window snapshot failed (see the CLI message above)." >&2
            return 1
        fi
        if [[ ! -f "$out_png" ]]; then
            echo "error: snapshot reported success but no PNG was written to $out_png." >&2
            return 1
        fi
    fi

    echo "→ captured $out_png (rendered content verified)" >&2
    return 0
}
