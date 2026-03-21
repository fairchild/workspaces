#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/codespaces-claude-worker.sh --run-id <id> --request-file <path> [--max-turns <n>]

Runs Claude Code in non-interactive mode inside a Codespace and stores artifacts
under .context/codespaces-claude-worker/<run-id>/.
EOF
}

log() {
  printf '[codespaces-claude-worker] %s\n' "$*" >&2
}

fail() {
  log "error: $*"
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

write_json() {
  local path="$1"
  local payload="$2"
  python3 - "$path" "$payload" <<'PY'
from __future__ import annotations

import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(sys.argv[2])
path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

run_id=""
request_file=""
max_turns="20"

while (($# > 0)); do
  case "$1" in
    --run-id)
      [[ $# -ge 2 ]] || fail "--run-id requires a value"
      run_id="$2"
      shift 2
      ;;
    --request-file)
      [[ $# -ge 2 ]] || fail "--request-file requires a value"
      request_file="$2"
      shift 2
      ;;
    --max-turns)
      [[ $# -ge 2 ]] || fail "--max-turns requires a value"
      max_turns="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ -n "$run_id" ]] || fail "--run-id is required"
[[ -n "$request_file" ]] || fail "--request-file is required"
[[ "$max_turns" =~ ^[1-9][0-9]*$ ]] || fail "--max-turns must be a positive integer"

require_command git
require_command python3
require_command claude

if [[ -z "${ANTHROPIC_API_KEY:-}" && -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
  fail "missing Claude credentials; set ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN in Codespaces secrets"
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

if [[ "$request_file" != /* ]]; then
  request_file="$repo_root/$request_file"
fi

[[ -f "$request_file" ]] || fail "request file not found: $request_file"
[[ -s "$request_file" ]] || fail "request file is empty: $request_file"

run_dir="$repo_root/.context/codespaces-claude-worker/$run_id"
mkdir -p "$run_dir"

request_copy="$run_dir/request.md"
response_path="$run_dir/response.json"
stderr_path="$run_dir/stderr.log"
status_path="$run_dir/status.json"
metadata_path="$run_dir/metadata.json"

cp "$request_file" "$request_copy"

started_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
write_json "$metadata_path" "$(python3 - "$repo_root" "$request_file" "$request_copy" "$max_turns" "$started_at" <<'PY'
from __future__ import annotations

import json
import sys

payload = {
    "repo_root": sys.argv[1],
    "request_file": sys.argv[2],
    "request_copy": sys.argv[3],
    "max_turns": int(sys.argv[4]),
    "started_at": sys.argv[5],
}
print(json.dumps(payload))
PY
)"

log "starting Claude run $run_id"

set +e
cat "$request_copy" | claude -p \
  --allow-dangerously-skip-permissions \
  --max-turns "$max_turns" \
  --output-format json \
  "Complete the task described on stdin. Treat stdin as the full request and follow it exactly." \
  >"$response_path" 2>"$stderr_path"
exit_code=$?
set -e

finished_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
write_json "$status_path" "$(python3 - "$exit_code" "$started_at" "$finished_at" "$response_path" "$stderr_path" <<'PY'
from __future__ import annotations

import json
import sys

payload = {
    "exit_code": int(sys.argv[1]),
    "started_at": sys.argv[2],
    "finished_at": sys.argv[3],
    "response_path": sys.argv[4],
    "stderr_path": sys.argv[5],
    "success": int(sys.argv[1]) == 0,
}
print(json.dumps(payload))
PY
)"

if [[ "$exit_code" -eq 0 ]]; then
  log "Claude run completed successfully; artifacts: $run_dir"
else
  log "Claude run failed with exit code $exit_code; artifacts: $run_dir"
fi

exit "$exit_code"
