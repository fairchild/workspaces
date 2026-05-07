#!/bin/bash
# Channel 4 — cold-start transcript replay perf scenario.
#
# Drives PerfChannel4Tests/replay10kRecords. Asserts the perf audit's two
# hard gates (perf-audit-pr443-final.md):
#   - replay completion < 25 seconds for 10,000 records at 500 ev/s
#   - RSS delta < 50 MB across the replay

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
TS="$(date +%Y%m%dT%H%M%S)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/output/perf/channel4/$TS/replay}"
mkdir -p "$OUT_DIR"

echo "[channel4-replay] out=$OUT_DIR"
WORKSPACES_PERF_RUN=1 \
WORKSPACES_PERF_OUT="$OUT_DIR/result.json" \
    swift test --filter replay10kRecords 2>&1 \
    | tee "$OUT_DIR/run.log" >/dev/null || true

if [[ -f "$OUT_DIR/result.json" ]]; then
    python3 -c "import json,sys; r=json.load(open('$OUT_DIR/result.json')); print(json.dumps(r, indent=2, sort_keys=True))"
else
    echo "no result.json produced; tail of log:"
    tail -n 25 "$OUT_DIR/run.log"
    exit 1
fi
