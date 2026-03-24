#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <template-path> [output-path]" >&2
  exit 1
fi

template_path="$1"
output_path="${2:-$(mktemp "${TMPDIR:-/tmp}/lume-unattended-XXXXXX.yml")}"
guest_password="${LUME_GUEST_PASSWORD:-${LUME_STANDALONE_SSH_PASSWORD:-}}"

umask 077

if [[ ! -f "$template_path" ]]; then
  echo "Template does not exist: $template_path" >&2
  exit 1
fi

if [[ -z "$guest_password" ]]; then
  echo "Set LUME_GUEST_PASSWORD (or LUME_STANDALONE_SSH_PASSWORD) before rendering unattended configs." >&2
  exit 1
fi

if [[ ! "$guest_password" =~ ^[A-Za-z0-9._-]{16,128}$ ]]; then
  echo "LUME_GUEST_PASSWORD must be 16-128 characters and only use letters, digits, ., _, or -." >&2
  exit 1
fi

python3 - "$template_path" "$output_path" "$guest_password" <<'PY'
from pathlib import Path
import sys

template_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
guest_password = sys.argv[3]

template = template_path.read_text()
rendered = template.replace("__LUME_GUEST_PASSWORD__", guest_password)
output_path.write_text(rendered)
PY

chmod 600 "$output_path"

printf '%s\n' "$output_path"
