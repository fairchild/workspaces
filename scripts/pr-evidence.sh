#!/bin/bash
# ==========================================================================
# pr-evidence.sh - Profile-driven PR evidence capture and upload
# ==========================================================================
#
# Usage:
#   ./scripts/pr-evidence.sh --pr 387 --profile swift-unit --filter Ghostty
#   ./scripts/pr-evidence.sh --pr 387 --profile ghostty-shortcuts
#   ./scripts/pr-evidence.sh --pr 387 --profile performance --scenario debug_no_activate \
#     --before-summary /tmp/before-summary.json --after-summary /tmp/after-summary.json
#
# Profiles:
#   swift-unit        Run focused Swift tests, full Swift tests, diff check, upload summary.
#   ghostty-shortcuts Build, launch debug app, drive Ghostty split shortcuts, upload log + window evidence.
#   performance       Compare canonical before/after perf summaries and upload a delta summary.
#
# ==========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PR=""
PROFILE=""
NAME=""
FILTER="Ghostty"
SCENARIO="debug_no_activate"
PERF_OUTPUT_DIR=""
SKIP_BEFORE=0
SKIP_AFTER=0
BEFORE_SUMMARY=""
AFTER_SUMMARY=""
UPLOAD=true
RUN_DIR=""
LAUNCH_WATCH_PID=""

usage() {
    cat <<'USAGE'
Usage: ./scripts/pr-evidence.sh --pr <number> --profile <profile> [options]

Options:
  --pr <number>         PR number for evidence upload.
  --profile <profile>   Evidence profile: swift-unit, ghostty-shortcuts, performance.
  --filter <pattern>    Focused Swift test filter for swift-unit (default: Ghostty).
  --scenario <id>       Canonical performance scenario (default: debug_no_activate).
  --perf-output-dir <p> Performance evidence output directory (default: run dir/performance).
  --skip-before         Performance profile: use --before-summary instead of capturing before.
  --skip-after          Performance profile: use --after-summary instead of capturing after.
  --before-summary <p>  Performance profile: existing before summary.json.
  --after-summary <p>   Performance profile: existing after summary.json.
  --name <slug>         Evidence slug prefix (default: profile name).
  --no-upload           Generate local artifacts without uploading.
  --help, -h            Show this help.

Examples:
  ./scripts/pr-evidence.sh --pr 387 --profile swift-unit --filter GhosttyRuntimeConfigFactory
  ./scripts/pr-evidence.sh --pr 387 --profile ghostty-shortcuts
  ./scripts/pr-evidence.sh --pr 387 --profile performance --scenario debug_no_activate \
    --before-summary /tmp/before/summary.json --after-summary /tmp/after/summary.json \
    --skip-before --skip-after
USAGE
}

log() {
    echo "[$(date +%H:%M:%S)] $*"
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pr)
                [[ $# -ge 2 ]] || fail "--pr requires a value"
                PR="$2"
                shift 2
                ;;
            --profile)
                [[ $# -ge 2 ]] || fail "--profile requires a value"
                PROFILE="$2"
                shift 2
                ;;
            --filter)
                [[ $# -ge 2 ]] || fail "--filter requires a value"
                FILTER="$2"
                shift 2
                ;;
            --scenario)
                [[ $# -ge 2 ]] || fail "--scenario requires a value"
                SCENARIO="$2"
                shift 2
                ;;
            --perf-output-dir)
                [[ $# -ge 2 ]] || fail "--perf-output-dir requires a value"
                PERF_OUTPUT_DIR="$2"
                shift 2
                ;;
            --skip-before)
                SKIP_BEFORE=1
                shift
                ;;
            --skip-after)
                SKIP_AFTER=1
                shift
                ;;
            --before-summary)
                [[ $# -ge 2 ]] || fail "--before-summary requires a value"
                BEFORE_SUMMARY="$2"
                shift 2
                ;;
            --after-summary)
                [[ $# -ge 2 ]] || fail "--after-summary requires a value"
                AFTER_SUMMARY="$2"
                shift 2
                ;;
            --name)
                [[ $# -ge 2 ]] || fail "--name requires a value"
                NAME="$2"
                shift 2
                ;;
            --no-upload)
                UPLOAD=false
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                fail "unknown argument: $1"
                ;;
        esac
    done

    [[ -n "$PR" ]] || fail "--pr is required"
    [[ -n "$PROFILE" ]] || fail "--profile is required"
    [[ -n "$NAME" ]] || NAME="$PROFILE"
}

init_run_dir() {
    local timestamp
    timestamp="$(date +%Y%m%d-%H%M%S)"
    RUN_DIR="$REPO_ROOT/output/evidence/pr-$PR/$timestamp-$PROFILE"
    mkdir -p "$RUN_DIR"
    log "Evidence run dir: $RUN_DIR"
}

run_logged() {
    local label="$1"
    shift

    local log_path="$RUN_DIR/$label.log"
    log "Running: $*"
    if "$@" >"$log_path" 2>&1; then
        log "PASS $label"
        return 0
    fi

    tail -n 120 "$log_path" >&2 || true
    fail "$label failed; see $log_path"
}

xml_escape() {
    sed \
        -e 's/&/\&amp;/g' \
        -e 's/</\&lt;/g' \
        -e 's/>/\&gt;/g' \
        -e 's/"/\&quot;/g'
}

first_match() {
    local pattern="$1"
    local file="$2"
    rg "$pattern" "$file" | tail -n 1 || true
}

svg_text() {
    local x="$1"
    local y="$2"
    local size="$3"
    local color="$4"
    local value="$5"
    local escaped
    escaped="$(printf '%s' "$value" | xml_escape)"
    printf '  <text x="%s" y="%s" font-family="Menlo, Consolas, monospace" font-size="%s" fill="%s">%s</text>\n' \
        "$x" "$y" "$size" "$color" "$escaped"
}

render_summary_svg() {
    local output="$1"
    local title="$2"
    shift 2
    local lines=("$@")

    {
        echo '<svg xmlns="http://www.w3.org/2000/svg" width="1500" height="820" viewBox="0 0 1500 820">'
        echo '  <rect width="1500" height="820" fill="#101820"/>'
        echo '  <rect x="44" y="44" width="1412" height="732" rx="10" fill="#16232f" stroke="#4f6f8f" stroke-width="2"/>'
        svg_text 78 102 30 "#f2f6fa" "$title"
        svg_text 78 144 19 "#b9cad8" "Generated by scripts/pr-evidence.sh profile=$PROFILE"

        local y=214
        local line
        for line in "${lines[@]}"; do
            if [[ "$line" == \$* ]]; then
                svg_text 78 "$y" 22 "#8bd5ff" "$line"
            elif [[ "$line" == NOTE:* ]]; then
                svg_text 78 "$y" 18 "#b9cad8" "$line"
            else
                svg_text 100 "$y" 21 "#b8f3c8" "$line"
            fi
            y=$((y + 42))
        done

        echo '</svg>'
    } >"$output"
}

upload_artifact() {
    local slug="$1"
    local file="$2"

    if [[ "$UPLOAD" != true ]]; then
        log "Upload skipped: $file"
        return 0
    fi

    "$REPO_ROOT/scripts/evidence.sh" --pr "$PR" --name "$slug" --file "$file"
}

profile_swift_unit() {
    require_cmd swift
    require_cmd rg

    run_logged "swift-test-focused" swift test --filter "$FILTER"
    run_logged "swift-test-full" swift test
    run_logged "git-diff-check" git diff --check

    local focused_summary full_summary factory_summary
    focused_summary="$(first_match 'Test run with .* tests? in .* suites? passed' "$RUN_DIR/swift-test-focused.log")"
    full_summary="$(first_match 'Test run with .* tests? in .* suites? passed' "$RUN_DIR/swift-test-full.log")"
    factory_summary="$(first_match 'Suite ".*" passed' "$RUN_DIR/swift-test-focused.log")"

    [[ -n "$focused_summary" ]] || focused_summary="Focused test summary not found"
    [[ -n "$full_summary" ]] || full_summary="Full test summary not found"
    [[ -n "$factory_summary" ]] || factory_summary="Focused suite summary not found"

    local svg_path="$RUN_DIR/$NAME.svg"
    render_summary_svg "$svg_path" "PR #$PR Swift Unit Evidence" \
        "\$ swift test --filter $FILTER" \
        "PASS $factory_summary" \
        "PASS $focused_summary" \
        "\$ swift test" \
        "PASS $full_summary" \
        "\$ git diff --check" \
        "PASS no whitespace errors" \
        "NOTE: logs stored in $RUN_DIR"

    upload_artifact "$NAME" "$svg_path"
}

wait_for_pattern() {
    local pattern="$1"
    local file="$2"
    local timeout_seconds="$3"

    local elapsed=0
    while ((elapsed < timeout_seconds)); do
        if [[ -f "$file" ]] && rg -q "$pattern" "$file"; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    return 1
}

window_click_coordinates() {
    swift - <<'SWIFT'
import CoreGraphics
import Foundation

let ownerCandidates: Set<String> = ["WorkSpaces", "WorkspaceManager"]
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

for window in windows {
    let owner = window[kCGWindowOwnerName as String] as? String ?? ""
    let layer = window[kCGWindowLayer as String] as? Int ?? 1
    guard ownerCandidates.contains(owner), layer == 0 else { continue }

    guard
        let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
        let x = bounds["X"],
        let y = bounds["Y"],
        let width = bounds["Width"],
        let height = bounds["Height"]
    else {
        continue
    }

    let clickX = Int(x + (width * 0.58))
    let clickY = Int(y + (height * 0.52))
    print("\(clickX),\(clickY)")
    exit(0)
}

exit(1)
SWIFT
}

cleanup_launch_watch() {
    if [[ -n "$LAUNCH_WATCH_PID" ]] && kill -0 "$LAUNCH_WATCH_PID" >/dev/null 2>&1; then
        kill "$LAUNCH_WATCH_PID" >/dev/null 2>&1 || true
        wait "$LAUNCH_WATCH_PID" 2>/dev/null || true
    fi
}

profile_ghostty_shortcuts() {
    require_cmd swift
    require_cmd rg
    require_cmd osascript
    require_cmd cliclick

    run_logged "build-ghosttykit" "$REPO_ROOT/scripts/build-ghosttykit.sh"
    run_logged "swift-build" swift build

    local launch_watch_log="$RUN_DIR/launch-watch.log"
    log "Launching debug app in watched mode"
    (
        cd "$REPO_ROOT"
        ./scripts/launch-dev.sh --no-build --watch
    ) >"$launch_watch_log" 2>&1 &
    LAUNCH_WATCH_PID=$!
    trap cleanup_launch_watch EXIT

    wait_for_pattern 'Log file: ' "$launch_watch_log" 45 || {
        tail -n 160 "$launch_watch_log" >&2 || true
        fail "debug launch did not report a log file"
    }

    local app_log
    app_log="$(sed -n 's/^.*Log file: //p' "$launch_watch_log" | tail -n 1)"
    [[ -n "$app_log" && -f "$app_log" ]] || fail "unable to resolve app log from launch output"

    wait_for_pattern 'first_prompt_ready' "$app_log" 45 || {
        tail -n 160 "$app_log" >&2 || true
        fail "terminal prompt readiness was not observed"
    }

    local coords
    osascript -e 'tell application "System Events" to set frontmost of process "WorkspaceManager" to true' >/dev/null
    coords="$(window_click_coordinates)" || fail "unable to resolve WorkspaceManager terminal click coordinates"
    cliclick "c:$coords" >/dev/null

    osascript -e 'tell application "System Events" to keystroke "d" using command down' >/dev/null
    sleep 1
    osascript -e 'tell application "System Events" to keystroke "[" using command down' >/dev/null
    sleep 1
    osascript -e 'tell application "System Events" to keystroke "]" using command down' >/dev/null

    wait_for_pattern '\[GhosttyAppManager\] action=new_split direction=' "$app_log" 15 || fail "missing new_split log evidence"
    wait_for_pattern '\[GhosttyAppManager\] action=goto_split direction=0' "$app_log" 15 || fail "missing previous goto_split log evidence"
    wait_for_pattern '\[GhosttyAppManager\] action=goto_split direction=1' "$app_log" 15 || fail "missing next goto_split log evidence"

    local screenshot="$RUN_DIR/$NAME-window.png"
    "$REPO_ROOT/scripts/capture-window.sh" --output "$screenshot" >"$RUN_DIR/capture-window.log" 2>&1

    local new_split previous_split next_split split_layout
    new_split="$(first_match '\[GhosttyAppManager\] action=new_split direction=' "$app_log")"
    split_layout="$(first_match '\[SplitRouting\] new_split layout' "$app_log")"
    previous_split="$(first_match '\[GhosttyAppManager\] action=goto_split direction=0' "$app_log")"
    next_split="$(first_match '\[GhosttyAppManager\] action=goto_split direction=1' "$app_log")"

    local svg_path="$RUN_DIR/$NAME-log.svg"
    render_summary_svg "$svg_path" "PR #$PR Ghostty Shortcut Smoke" \
        "\$ ./scripts/build-ghosttykit.sh" \
        "PASS Built GhosttyKit.xcframework" \
        "\$ swift build" \
        "PASS Build complete" \
        "Runtime log evidence" \
        "PASS $new_split" \
        "PASS $split_layout" \
        "PASS $previous_split" \
        "PASS $next_split" \
        "NOTE: app log $app_log" \
        "NOTE: screenshot $screenshot"

    upload_artifact "$NAME-log" "$svg_path"
    upload_artifact "$NAME-window" "$screenshot"
}

profile_performance() {
    local perf_dir="$PERF_OUTPUT_DIR"
    if [[ -z "$perf_dir" ]]; then
        perf_dir="$RUN_DIR/performance"
    fi
    mkdir -p "$perf_dir"

    local args=(--scenario "$SCENARIO" --output-dir "$perf_dir")
    if [[ "$SKIP_BEFORE" -eq 1 ]]; then
        args+=(--skip-before)
    fi
    if [[ "$SKIP_AFTER" -eq 1 ]]; then
        args+=(--skip-after)
    fi
    if [[ -n "$BEFORE_SUMMARY" ]]; then
        args+=(--before-summary "$BEFORE_SUMMARY")
    fi
    if [[ -n "$AFTER_SUMMARY" ]]; then
        args+=(--after-summary "$AFTER_SUMMARY")
    fi

    run_logged "performance-evidence" "$REPO_ROOT/scripts/prepare-perf-evidence.sh" "${args[@]}"

    local compare_output="$perf_dir/compare.txt"
    [[ -f "$compare_output" ]] || fail "missing performance comparison output: $compare_output"

    local before_path="$BEFORE_SUMMARY"
    local after_path="$AFTER_SUMMARY"
    if [[ -z "$before_path" ]]; then
        before_path="$perf_dir/before/summary.json"
    fi
    if [[ -z "$after_path" ]]; then
        after_path="$perf_dir/after/summary.json"
    fi

    local before_label="${before_path/#$REPO_ROOT\//}"
    local after_label="${after_path/#$REPO_ROOT\//}"
    local markdown_path="$RUN_DIR/$NAME.md"
    {
        echo "Performance evidence for PR #$PR"
        echo ""
        echo "- Scenario ID: \`$SCENARIO\`"
        echo "- Before Summary: \`$before_path\`"
        echo "- After Summary: \`$after_path\`"
        echo "- Delta Summary:"
        echo ""
        echo '```'
        cat "$compare_output"
        echo '```'
        echo ""
        echo "Local artifacts: \`$perf_dir\`"
    } >"$markdown_path"

    local svg_lines=(
        "Scenario: $SCENARIO"
        "Before: $before_label"
        "After: $after_label"
        "Delta summary:"
    )
    local line
    local count=0
    while IFS= read -r line && [[ "$count" -lt 8 ]]; do
        svg_lines+=("$line")
        count=$((count + 1))
    done <"$compare_output"

    local svg_path="$RUN_DIR/$NAME.svg"
    render_summary_svg "$svg_path" "PR #$PR Performance Evidence" "${svg_lines[@]}" \
        "NOTE: PR markdown stored in $markdown_path"

    upload_artifact "$NAME" "$svg_path"
    log "Performance PR markdown: $markdown_path"
}

main() {
    parse_args "$@"
    init_run_dir

    case "$PROFILE" in
        swift-unit)
            profile_swift_unit
            ;;
        ghostty-shortcuts)
            profile_ghostty_shortcuts
            ;;
        performance)
            profile_performance
            ;;
        *)
            fail "unknown profile: $PROFILE"
            ;;
    esac
}

main "$@"
