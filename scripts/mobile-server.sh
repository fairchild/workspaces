#!/bin/bash
# Cold-starts the mobile-pairing web-next server WITHOUT the app: same port,
# data dir, and minted token as the app's own embedded child, so a paired
# phone works identically whichever side started it. The app and this script
# are mutually exclusive owners of the port — if something already listens
# there (usually the app's child), this is a no-op, not a failure.
set -euo pipefail

PORT=3140
DATA_DIR="$HOME/Library/Application Support/WorkspaceManager/web-next"
ROOT="$(cd "$(dirname "$0")/.." && pwd)/web-next"

if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN > /dev/null 2>&1; then
  echo "A server already listens on :$PORT (probably the app's embedded child) — nothing to do."
  exit 0
fi

TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale
ORIGIN=""
if [ -x "$TS" ]; then
  DNS=$("$TS" status --json 2> /dev/null \
    | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' \
    2> /dev/null || true)
  if [ -n "$DNS" ]; then
    ORIGIN="https://$DNS"
    if ! "$TS" serve status 2> /dev/null | grep -q "127.0.0.1:$PORT"; then
      echo "note: tailscale serve is not fronting :$PORT — one-time: tailscale serve --bg $PORT"
    fi
  fi
else
  echo "note: Tailscale CLI not found — serving loopback only, no tailnet origin."
fi

cd "$ROOT"
export PORT
export WEB_NEXT_DATA_DIR="$DATA_DIR"
if [ -n "$ORIGIN" ]; then
  export WEB_NEXT_EXTRA_LOCAL_ORIGINS="$ORIGIN"
fi
exec pnpm run start:local
