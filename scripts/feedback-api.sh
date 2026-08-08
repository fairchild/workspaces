#!/usr/bin/env bash
# CLI for the feedback store's agent API (infra/feedback-store/CONTRACT.md § Agent API).
# Used by the product-triage persona to list, inspect, update, and publish
# feedback rows. Requires FEEDBACK_AGENT_TOKEN (auto-sourced from .env).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -z "${FEEDBACK_AGENT_TOKEN:-}" && -f "$REPO_ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.env"
  set +a
fi

BASE_URL="${FEEDBACK_API_BASE:-https://feedback.cloudcompute.com}"
ACTOR="${FEEDBACK_AGENT_ACTOR:-cli}"

usage() {
  cat <<'EOF'
Usage: feedback-api.sh <command> [args]

Commands:
  list [status] [kind]          List rows, newest first (status/kind filters optional)
  show <id>                     One row plus its audit trail
  update <id> <status> [notes]  Set status (new|triaged|planned|resolved|wont_fix) and optional notes
  publish <title> <body> <id...>  Publish rows as one GitHub issue (guarded against dupes)

Environment:
  FEEDBACK_AGENT_TOKEN  required; auto-sourced from repo .env
  FEEDBACK_API_BASE     default https://feedback.cloudcompute.com
  FEEDBACK_AGENT_ACTOR  audit identity, default "cli"
EOF
  exit 1
}

[[ $# -ge 1 ]] || usage
[[ -n "${FEEDBACK_AGENT_TOKEN:-}" ]] || { echo "error: FEEDBACK_AGENT_TOKEN is not set" >&2; exit 1; }

api() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS -X "$method" "$BASE_URL$path" -K - -H "X-Agent-Actor: $ACTOR")
  if [[ -n "$body" ]]; then
    args+=(-H "Content-Type: application/json" --data "$body")
  fi
  # Auth header arrives via stdin config (-K -) so the token never hits argv.
  curl "${args[@]}" <<EOF
header = "Authorization: Bearer $FEEDBACK_AGENT_TOKEN"
EOF
  echo
}

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

command="$1"
shift
case "$command" in
  list)
    query=""
    [[ -n "${1:-}" ]] && query="status=$1"
    [[ -n "${2:-}" ]] && query="$query&kind=$2"
    api GET "/api/feedback${query:+?$query}"
    ;;
  show)
    [[ $# -eq 1 ]] || usage
    api GET "/api/feedback/$1"
    ;;
  update)
    [[ $# -ge 2 ]] || usage
    id="$1"
    body="{\"status\": $(json_escape "$2")"
    [[ $# -ge 3 ]] && body="$body, \"admin_notes\": $(json_escape "$3")"
    body="$body}"
    api PATCH "/api/feedback/$id" "$body"
    ;;
  publish)
    [[ $# -ge 3 ]] || usage
    title="$1"
    text="$2"
    shift 2
    ids=""
    for id in "$@"; do
      ids="$ids$(json_escape "$id"),"
    done
    api POST "/api/feedback/publish" \
      "{\"ids\": [${ids%,}], \"title\": $(json_escape "$title"), \"body\": $(json_escape "$text")}"
    ;;
  *)
    usage
    ;;
esac
