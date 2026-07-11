#!/usr/bin/env bash
# ==========================================================================
# evidence.sh — Capture screenshot + upload to R2 evidence store in one step
# ==========================================================================
#
# Usage:
#   ./scripts/evidence.sh --pr 253 --name sticky-tab-bar
#   ./scripts/evidence.sh --pr 253 --name before-fix --file /tmp/existing.png
#   ./scripts/evidence.sh --pr 253 --name test-results --file test-output.png --no-capture
#
#   # One-command app evidence (first-choice UI capture): launch a named fixture
#   # state, snapshot the main window via operator scope, upload — headless-safe,
#   # no activation, no focus steal.
#   ./scripts/evidence.sh --pr 253 --fixture phase-1-release
#
# Outputs the uploaded URL to stdout and markdown-ready evidence to stderr.
# ==========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/fixture-scenarios.sh
source "$SCRIPT_DIR/lib/fixture-scenarios.sh"
# shellcheck source=lib/app-capture.sh
source "$SCRIPT_DIR/lib/app-capture.sh"

source_env_file() {
  local env_path="$1"
  [[ -f "$env_path" ]] || return 1

  set -a
  # shellcheck disable=SC1091
  source "$env_path"
  set +a
}

env_source_for() {
  local envfile="$1"
  local candidate=""
  local git_common=""
  local worktree_path=""

  if [[ -n "${CONDUCTOR_ROOT_PATH:-}" ]]; then
    candidate="$CONDUCTOR_ROOT_PATH/$envfile"
    [[ "$candidate" != "$REPO_ROOT/$envfile" && -f "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
  fi

  candidate="$HOME/code/$(basename "$REPO_ROOT")/$envfile"
  if [[ "$candidate" != "$REPO_ROOT/$envfile" && -f "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  git_common="$(git rev-parse --git-common-dir 2>/dev/null || true)"
  if [[ -n "$git_common" ]]; then
    [[ "$git_common" == /* ]] || git_common="$REPO_ROOT/$git_common"
    if [[ "$git_common" == */.git ]]; then
      candidate="${git_common%/.git}/$envfile"
      [[ "$candidate" != "$REPO_ROOT/$envfile" && -f "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
    fi
  fi

  while IFS= read -r line; do
    [[ "$line" == worktree\ * ]] || continue
    worktree_path="${line#worktree }"
    if [[ "$worktree_path" != "$REPO_ROOT" && -f "$worktree_path/$envfile" ]]; then
      printf '%s\n' "$worktree_path/$envfile"
      return 0
    fi
  done < <(git worktree list --porcelain 2>/dev/null)

  return 1
}

load_evidence_env() {
  local envfile=""
  local env_source=""

  [[ -n "${EVIDENCE_UPLOAD_TOKEN:-}" ]] && return 0

  for envfile in .env .env.local; do
    if [[ -f "$REPO_ROOT/$envfile" ]]; then
      source_env_file "$REPO_ROOT/$envfile"
      [[ -n "${EVIDENCE_UPLOAD_TOKEN:-}" ]] && return 0
    fi
  done

  for envfile in .env .env.local; do
    env_source="$(env_source_for "$envfile" || true)"
    if [[ -n "$env_source" ]]; then
      source_env_file "$env_source"
      [[ -n "${EVIDENCE_UPLOAD_TOKEN:-}" ]] && return 0
    fi
  done
}

load_evidence_env

PR=""
NAME=""
FILE=""
CAPTURE=true
REPO="workspaces"
FIXTURE=""
FIXTURE_TIMEOUT=45
KEEP_RUNNING=false

usage() {
  cat <<EOF
Usage: $(basename "$0") --pr <number> --name <slug> [options]
       $(basename "$0") --pr <number> --fixture <scenario> [options]

Options:
  --pr <number>       PR number (required)
  --name <slug>       Evidence slug for filename (default in fixture mode: the scenario)
  --file <path>       Use existing file instead of capturing screenshot
  --no-capture        Skip screenshot capture (requires --file)
  --repo <name>       Repository short name (default: workspaces)

App evidence lane (first-choice UI capture — sanctioned by [A1]):
  --fixture <name>    Launch the debug app in a named fixture state with operator
                      scope, snapshot the main window (no activation, no focus
                      steal), then upload. Known: $(fixture_scenario_names | paste -sd, -),
                      or inline:<agent-states>. See docs/development/ui-fixture-mode.md.
  --timeout <s>       Readiness timeout for the app launch (default: ${FIXTURE_TIMEOUT})
  --keep-running      Leave the launched app running after capture (debugging)

  -h, --help          Show this help
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr) PR="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --file) FILE="$2"; CAPTURE=false; shift 2 ;;
    --no-capture) CAPTURE=false; shift ;;
    --repo) REPO="$2"; shift 2 ;;
    --fixture) FIXTURE="$2"; shift 2 ;;
    --timeout) FIXTURE_TIMEOUT="$2"; shift 2 ;;
    --keep-running) KEEP_RUNNING=true; shift ;;
    -h|--help) usage ;;
    *) echo "error: unknown option: $1" >&2; usage ;;
  esac
done

# Fixture mode: the app self-capture lane produces the file, so --name defaults
# to the scenario and screencapture is not used.
if [[ -n "$FIXTURE" ]]; then
  CAPTURE=false
  [[ -n "$NAME" ]] || NAME="${FIXTURE#inline:}"
  NAME="${NAME//[^a-zA-Z0-9._-]/-}"
fi

if [[ -z "$PR" ]] || [[ -z "$NAME" ]]; then
  echo "error: --pr and --name are required (--name defaults to the scenario in --fixture mode)" >&2
  usage
fi

if [[ -z "${EVIDENCE_UPLOAD_TOKEN:-}" ]]; then
  echo "error: EVIDENCE_UPLOAD_TOKEN not set." >&2
  echo "  Add it to $REPO_ROOT/.env, run ./scripts/setup --env-only to symlink it from an existing checkout, or export it directly." >&2
  echo "  The token value is stored in GitHub repo secrets." >&2
  exit 1
fi

# App evidence lane: launch a named fixture state and snapshot the main window
# through operator scope. Headless-safe and locked-screen-aware — see
# docs/development/evidence.md § "App evidence lane".
if [[ -n "$FIXTURE" ]]; then
  FILE="/tmp/evidence-${NAME}-$(date +%Y%m%d-%H%M%S).png"
  if [[ "$KEEP_RUNNING" != "true" ]]; then
    trap app_capture_stop EXIT
  fi
  if ! app_capture_window "$FILE" "$FIXTURE" "$FIXTURE_TIMEOUT"; then
    echo "error: app evidence capture failed for fixture '$FIXTURE'." >&2
    exit 1
  fi
fi

# Capture screenshot if no file provided
if [[ "$CAPTURE" == "true" ]]; then
  FILE="/tmp/evidence-${NAME}-$(date +%Y%m%d-%H%M%S).png"
  echo "Capturing screenshot → $FILE" >&2
  screencapture -x "$FILE"
fi

if [[ ! -f "$FILE" ]]; then
  echo "error: file not found: $FILE" >&2
  exit 1
fi

# Upload
URL=$(uv run "$REPO_ROOT/scripts/upload-evidence.py" "$FILE" \
  --repo "$REPO" --pr "$PR" --name "$NAME")

echo "" >&2
echo "Uploaded: $URL" >&2
echo "" >&2
echo "Markdown:" >&2
FILE_EXT="${FILE##*.}"
case "$FILE_EXT" in
  [Ww][Ee][Bb][Mm]|[Mm][Pp]4) echo "[${NAME}](${URL})" >&2 ;;
  *) echo "![${NAME}](${URL})" >&2 ;;
esac
echo "" >&2

# Print just the URL to stdout for piping
echo "$URL"
