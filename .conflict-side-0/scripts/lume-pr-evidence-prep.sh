#!/bin/bash
# ==========================================================================
# lume-pr-evidence-prep.sh - Prepare a GitHub-ready evidence bundle from a
# real-host Lume smoke run.
# ==========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

HOST_SMOKE_DIR="$REPO_ROOT/output/lume-host-smoke/latest"
OUTPUT_DIR=""
PR_NUMBER=""
PR_URL=""
COMMENT_PATH=""
ZIP_PATH=""

usage() {
    cat <<'USAGE'
Usage: ./scripts/lume-pr-evidence-prep.sh [options]

Options:
  --host-smoke-dir <path>  Host-smoke run directory (default: ./output/lume-host-smoke/latest)
  --output-dir <path>      Directory to write the generated comment + zip
                           (default: host-smoke dir)
  --pr <number>            PR number used in filenames and, when possible, PR URL lookup
  --help, -h               Show this help

This script does not upload files to GitHub. It prepares:
- a ready-to-paste PR evidence comment
- a zip containing the screenshots and supporting logs
USAGE
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

log() {
    echo "[$(date +%H:%M:%S)] $*"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --host-smoke-dir)
                [[ $# -ge 2 ]] || fail "--host-smoke-dir requires a value"
                HOST_SMOKE_DIR="$2"
                shift 2
                ;;
            --output-dir)
                [[ $# -ge 2 ]] || fail "--output-dir requires a value"
                OUTPUT_DIR="$2"
                shift 2
                ;;
            --pr)
                [[ $# -ge 2 ]] || fail "--pr requires a value"
                PR_NUMBER="$2"
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

resolve_path() {
    local raw_path="$1"
    if [[ -d "$raw_path" ]]; then
        (
            cd "$raw_path"
            pwd -P
        )
        return
    fi

    if [[ -e "$raw_path" ]]; then
        local parent
        parent="$(cd "$(dirname "$raw_path")" && pwd -P)"
        printf "%s/%s\n" "$parent" "$(basename "$raw_path")"
        return
    fi

    return 1
}

require_file() {
    local target="$1"
    [[ -f "$target" ]] || fail "Required file missing: $target"
}

summary_value() {
    local label="$1"
    local summary_path="$2"
    sed -n "s/^- ${label}: //p" "$summary_path" | head -n 1
}

lookup_pr_url() {
    [[ -n "$PR_NUMBER" ]] || return 0
    command -v gh >/dev/null 2>&1 || return 0
    PR_URL="$(gh pr view "$PR_NUMBER" --repo fairchild/workspaces --json url --jq .url 2>/dev/null || true)"
}

write_comment() {
    local summary_path="$1"
    local events_path="$2"
    local launch_log_path="$3"
    local detached_launch_path="$4"
    local ssh_probe_path="$5"
    local start_screenshot_path="$6"
    local final_screenshot_path="$7"
    local elapsed_seconds
    local outcome_message
    local ssh_probe_result

    elapsed_seconds="$(summary_value "Elapsed seconds" "$summary_path")"
    outcome_message="$(summary_value "Message" "$summary_path")"
    ssh_probe_result="$(tr -d '\n' <"$ssh_probe_path")"

    cat >"$COMMENT_PATH" <<EOF
## Evidence

${PR_URL:+PR: $PR_URL}
- Command: \`./scripts/lume-host-macos-smoke.sh --no-build\`
  - Result: ${outcome_message:-Smoke run completed.}${elapsed_seconds:+ Elapsed: ${elapsed_seconds}s.}
  - Summary: attach \`summary.md\`
  - Logs: attach \`launch.log\`, \`events.jsonl\`, and \`ssh-probe.txt\`
  - Visual proof: attach \`$(basename "$start_screenshot_path")\` and \`$(basename "$final_screenshot_path")\`
  - Detached launch proof:
    - \`launch.log\` includes \`[LumeCLIRunner] action=launch_detached ...\`
    - \`events.jsonl\` records \`launchLogPath\` on the persisted and active workspace milestones
    - \`ssh-probe.txt\` contains \`${ssh_probe_result:-WORKSPACES_LUME_SMOKE_OK}\`

Add test results above or below this block using the exact commands run on the reviewed commit.

Suggested PR body updates:

- In \`## Evidence\`, check:
  - \`UI-affecting change with PR-attached evidence from the exact commit under review\`
- In \`Evidence links\`, add the uploaded screenshot and bundle attachment URLs
- In \`## Blockers\`, leave \`Blocked on evidence\` unchecked once the files are attached in GitHub

Attachment set:

- \`$(basename "$start_screenshot_path")\`
- \`$(basename "$final_screenshot_path")\`
- \`$(basename "$summary_path")\`
- \`$(basename "$launch_log_path")\`
- \`$(basename "$events_path")\`
- \`$(basename "$ssh_probe_path")\`
- \`$(basename "$detached_launch_path")\`
- \`$(basename "$ZIP_PATH")\`
EOF
}

write_readme() {
    local readme_path="$1"
    cat >"$readme_path" <<EOF
# Semi-Manual PR Evidence Upload

1. Open the target PR in GitHub${PR_URL:+: $PR_URL}
2. Start a new comment on the PR
3. Paste the contents of:
   - \`$COMMENT_PATH\`
4. Drag these files into the comment so GitHub hosts them:
   - \`01-launch.png\`
   - \`02-final.png\`
   - \`$(basename "$ZIP_PATH")\`
5. After GitHub uploads the files, copy the attachment links into the PR body's \`Evidence links:\` section
6. Mark the PR evidence checkbox complete and clear \`Blocked on evidence\`

Notes:
- \`$(basename "$ZIP_PATH")\` already contains \`summary.md\`, \`launch.log\`, \`events.jsonl\`, \`ssh-probe.txt\`, the screenshots, and the generated comment template.
- \`detached-launch.log\` may be empty on healthy runs. The stronger detached-launch proof is the log marker in \`launch.log\` plus \`launchLogPath\` in \`events.jsonl\`.
EOF
}

main() {
    parse_args "$@"

    HOST_SMOKE_DIR="$(resolve_path "$HOST_SMOKE_DIR")" || fail "Host-smoke directory not found: $HOST_SMOKE_DIR"
    OUTPUT_DIR="${OUTPUT_DIR:-$HOST_SMOKE_DIR}"
    mkdir -p "$OUTPUT_DIR"
    OUTPUT_DIR="$(resolve_path "$OUTPUT_DIR")" || fail "Could not resolve output directory: $OUTPUT_DIR"

    local summary_path="$HOST_SMOKE_DIR/summary.md"
    local events_path="$HOST_SMOKE_DIR/events.jsonl"
    local launch_log_path="$HOST_SMOKE_DIR/launch.log"
    local detached_launch_path="$HOST_SMOKE_DIR/detached-launch.log"
    local ssh_probe_path="$HOST_SMOKE_DIR/ssh-probe.txt"
    local start_screenshot_path="$HOST_SMOKE_DIR/01-launch.png"
    local final_screenshot_path="$HOST_SMOKE_DIR/02-final.png"

    require_file "$summary_path"
    require_file "$events_path"
    require_file "$launch_log_path"
    require_file "$detached_launch_path"
    require_file "$ssh_probe_path"
    require_file "$start_screenshot_path"
    require_file "$final_screenshot_path"

    grep -q "Outcome: passed" "$summary_path" \
        || fail "Host-smoke run did not pass: $summary_path"
    rg -q '"type":"workspace_active"' "$events_path" \
        || fail "events.jsonl does not include workspace_active"
    rg -q '"launchLogPath"' "$events_path" \
        || fail "events.jsonl does not include launchLogPath"
    rg -q 'action=launch_detached' "$launch_log_path" \
        || fail "launch.log does not include the detached launch marker"
    grep -q 'WORKSPACES_LUME_SMOKE_OK' "$ssh_probe_path" \
        || fail "ssh-probe.txt does not include WORKSPACES_LUME_SMOKE_OK"

    lookup_pr_url

    local prefix="pr-evidence"
    if [[ -n "$PR_NUMBER" ]]; then
        prefix="pr-${PR_NUMBER}-evidence"
    fi

    COMMENT_PATH="$OUTPUT_DIR/${prefix}-comment.md"
    ZIP_PATH="$OUTPUT_DIR/${prefix}.zip"
    local readme_path="$OUTPUT_DIR/${prefix}-README.md"

    write_comment \
        "$summary_path" \
        "$events_path" \
        "$launch_log_path" \
        "$detached_launch_path" \
        "$ssh_probe_path" \
        "$start_screenshot_path" \
        "$final_screenshot_path"

    rm -f "$ZIP_PATH"
    zip -j "$ZIP_PATH" \
        "$start_screenshot_path" \
        "$final_screenshot_path" \
        "$summary_path" \
        "$launch_log_path" \
        "$events_path" \
        "$ssh_probe_path" \
        "$detached_launch_path" \
        "$COMMENT_PATH" \
        >/dev/null

    write_readme "$readme_path"

    log "Prepared PR evidence bundle."
    log "Comment template: $COMMENT_PATH"
    log "Zip bundle: $ZIP_PATH"
    log "Upload guide: $readme_path"
}

main "$@"
