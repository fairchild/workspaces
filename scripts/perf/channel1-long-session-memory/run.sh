#!/bin/bash
# Channel 1 — Scenario C: register/deregister symmetry over a long session.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
TS="$(date +%Y%m%dT%H%M%S)"
DURATION="${DURATION:-600}"   # 10 minutes default
OUT_DIR="${OUT_DIR:-$ROOT_DIR/output/perf/channel1/$TS/long-session-memory}"
mkdir -p "$OUT_DIR"

echo "[long-session-memory] duration=${DURATION}s out=$OUT_DIR"
WORKSPACES_PERF_RUN=1 \
WORKSPACES_PERF_LONG_SECONDS="$DURATION" \
WORKSPACES_PERF_OUT="$OUT_DIR/result.json" \
    swift test --filter longSessionRegistrySymmetry 2>&1 \
    | tee "$OUT_DIR/run.log" >/dev/null

if [[ -f "$OUT_DIR/result.json" ]]; then
    python3 -c "import json,sys; r=json.load(open('$OUT_DIR/result.json')); print(json.dumps(r, indent=2, sort_keys=True))"
else
    echo "no result.json produced; tail of log:"
    tail -n 25 "$OUT_DIR/run.log"
    exit 1
fi
