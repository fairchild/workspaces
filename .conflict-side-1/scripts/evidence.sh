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
# Outputs markdown-ready image link to stdout.
# ==========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source .env for EVIDENCE_UPLOAD_TOKEN if not already set
if [[ -z "${EVIDENCE_UPLOAD_TOKEN:-}" ]] && [[ -f "$REPO_ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.env"
  set +a
fi

PR=""
NAME=""
FILE=""
CAPTURE=true
REPO="workspaces"

usage() {
  cat <<EOF
Usage: $(basename "$0") --pr <number> --name <slug> [options]

Options:
  --pr <number>     PR number (required)
  --name <slug>     Evidence slug for filename (required)
  --file <path>     Use existing file instead of capturing screenshot
  --no-capture      Skip screenshot capture (requires --file)
  --repo <name>     Repository short name (default: workspaces)
  -h, --help        Show this help
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
    -h|--help) usage ;;
    *) echo "error: unknown option: $1" >&2; usage ;;
  esac
done

if [[ -z "$PR" ]] || [[ -z "$NAME" ]]; then
  echo "error: --pr and --name are required" >&2
  usage
fi

if [[ -z "${EVIDENCE_UPLOAD_TOKEN:-}" ]]; then
  echo "error: EVIDENCE_UPLOAD_TOKEN not set." >&2
  echo "  Add it to $REPO_ROOT/.env or export it directly." >&2
  echo "  The token value is stored in GitHub repo secrets." >&2
  exit 1
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
echo "![${NAME}](${URL})" >&2
echo "" >&2

# Print just the URL to stdout for piping
echo "$URL"
