#!/usr/bin/env bash
# Wait for a commit's CI check-runs to reach terminal states, then exit 0 (all
# green/skipped) or 1. Replaces the ad-hoc curl/jq poll loops sessions kept
# reimplementing (one shipped with an early-exit bug on 2026-07-02 — this is
# the tested single copy).
set -euo pipefail

usage() {
  echo "Usage: $(basename "$0") <sha> [--repo owner/name] [--interval seconds]" >&2
  echo "  Waits for all check-runs on <sha> to complete. Requires GH_TOKEN." >&2
}

SHA="${1:-}"
[[ -z "$SHA" || "$SHA" == "-h" || "$SHA" == "--help" ]] && { usage; exit 2; }
shift

REPO="fairchild/workspaces"
INTERVAL=45
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

: "${GH_TOKEN:?GH_TOKEN is required}"
API="https://api.github.com/repos/${REPO}/commits/${SHA}"
AUTH=(-H "Authorization: Bearer ${GH_TOKEN}" -H "Accept: application/vnd.github+json")

checks_settled() {
  curl -sf "${AUTH[@]}" "${API}/check-runs" |
    jq -e '(.total_count > 0) and ([[.check_runs | group_by(.name)[] | max_by(.started_at)][] | select(.status != "completed")] | length == 0)' >/dev/null
}

until checks_settled; do
  sleep "$INTERVAL"
done

# Superseded runs (e.g. cancelled re-triggers) linger on the SHA; judge and
# report only the latest run per check name.
LATEST='[.check_runs | group_by(.name)[] | max_by(.started_at)]'

echo "== check runs (latest per name) =="
curl -sf "${AUTH[@]}" "${API}/check-runs" |
  jq -r "${LATEST} | .[] | \"\(.name): \(.conclusion)\"" | sort -u

BAD_CHECKS=$(curl -sf "${AUTH[@]}" "${API}/check-runs" |
  jq "${LATEST} | [.[] | select(.conclusion != null and .conclusion != \"success\" and .conclusion != \"skipped\" and .conclusion != \"neutral\")] | length")
[[ "$BAD_CHECKS" == "0" ]]
