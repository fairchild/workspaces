#!/bin/bash
# Channel 1 — Scenario A: ingest burst.
#
# Runs the in-process Swift Testing perf scenario `ingestBurst` 5 times and
# emits result.json files under output/perf/channel1/<timestamp>/.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
ITER="${ITER:-5}"
TS="$(date +%Y%m%dT%H%M%S)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/output/perf/channel1/$TS/ingest-burst}"
mkdir -p "$OUT_DIR"

echo "[ingest-burst] iterations=$ITER out=$OUT_DIR"
for i in $(seq 1 "$ITER"); do
    echo "[ingest-burst] run $i"
    OUT="$OUT_DIR/run-$i.json"
    WORKSPACES_PERF_RUN=1 \
    WORKSPACES_PERF_OUT="$OUT" \
        swift test --filter ingestBurst 2>&1 \
        | tee "$OUT_DIR/run-$i.log" >/dev/null || true
    if [[ ! -f "$OUT" ]]; then
        echo "  -> no result.json produced; tail of log:"
        tail -n 25 "$OUT_DIR/run-$i.log" || true
    fi
done

# Emit a roll-up: median over the 5 runs of each summary statistic.
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

agg = {"scenario": "channel1_ingest_burst", "runs": len(runs), "metrics": {}}
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

echo "[ingest-burst] rollup at $OUT_DIR/rollup.json"
