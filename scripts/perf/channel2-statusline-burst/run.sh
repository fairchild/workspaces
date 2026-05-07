#!/bin/bash
# Channel 2 — status-line ingest burst.
#
# Mirrors the pattern of channel1-ingest-burst/run.sh but exercises the
# /statusline route. 8 sessions × 1 Hz status-line is well within the ingest
# budget per the perf-audit-pr443-final.md carry-forward; this driver exists so
# regressions get caught on the same Scenario A grid.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
ITER="${ITER:-5}"
TS="$(date +%Y%m%dT%H%M%S)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/output/perf/channel2/$TS/statusline-burst}"
mkdir -p "$OUT_DIR"

echo "[statusline-burst] iterations=$ITER out=$OUT_DIR"
for i in $(seq 1 "$ITER"); do
    echo "[statusline-burst] run $i"
    OUT="$OUT_DIR/run-$i.json"
    WORKSPACES_PERF_RUN=1 \
    WORKSPACES_PERF_OUT="$OUT" \
        swift test --filter statusLineBurst 2>&1 \
        | tee "$OUT_DIR/run-$i.log" >/dev/null || true
    if [[ ! -f "$OUT" ]]; then
        echo "  -> no result.json produced; tail of log:"
        tail -n 25 "$OUT_DIR/run-$i.log" || true
    fi
done

# Roll-up: median over runs.
python3 - "$OUT_DIR" "$ITER" <<'PY'
import json
import statistics
import sys
from pathlib import Path

out_dir = Path(sys.argv[1])
iters = int(sys.argv[2])
runs = []
for i in range(1, iters + 1):
    f = out_dir / f"run-{i}.json"
    if f.exists():
        runs.append(json.loads(f.read_text()))

if not runs:
    print("no successful runs", file=sys.stderr)
    sys.exit(1)

agg = {"scenario": "channel2_statusline_burst", "runs": len(runs), "metrics": {}}
metric_names = list(runs[0]["metrics"].keys())
for m in metric_names:
    agg["metrics"][m] = {}
    sample = runs[0]["metrics"][m]
    for stat in sample.keys():
        vals = [r["metrics"][m][stat] for r in runs if stat in r["metrics"].get(m, {})]
        if vals:
            agg["metrics"][m][stat] = statistics.median(vals)

(out_dir / "rollup.json").write_text(json.dumps(agg, indent=2, sort_keys=True))
print(json.dumps(agg, indent=2, sort_keys=True))
PY

echo "[statusline-burst] rollup at $OUT_DIR/rollup.json"
