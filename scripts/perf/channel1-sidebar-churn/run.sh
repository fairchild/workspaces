#!/bin/bash
# Channel 1 — Scenario B: sidebar churn (8 sessions × 5 ev/s × 60s).
#
# Runs the in-process Swift Testing perf scenario `sidebarChurn` once and emits
# result.json under output/perf/channel1/<timestamp>/sidebar-churn/.
#
# Note: this samples the *test process* CPU/RSS, not the live macOS app. The
# code paths under measurement (AgentHookListener, AgentSessionRegistry) are
# identical, but the SwiftUI binding layer is excluded. For a real-app
# measurement, see the README in this directory.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
TS="$(date +%Y%m%dT%H%M%S)"
DURATION="${DURATION:-60}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/output/perf/channel1/$TS/sidebar-churn}"
mkdir -p "$OUT_DIR"

echo "[sidebar-churn] duration=${DURATION}s out=$OUT_DIR"
WORKSPACES_PERF_RUN=1 \
WORKSPACES_PERF_CHURN_SECONDS="$DURATION" \
WORKSPACES_PERF_OUT="$OUT_DIR/result.json" \
    swift test --filter sidebarChurn 2>&1 \
    | tee "$OUT_DIR/run.log" >/dev/null

if [[ -f "$OUT_DIR/result.json" ]]; then
    python3 -c "import json,sys; r=json.load(open('$OUT_DIR/result.json')); print(json.dumps(r['metrics'], indent=2))"
else
    echo "no result.json produced; tail of log:"
    tail -n 25 "$OUT_DIR/run.log"
    exit 1
fi
