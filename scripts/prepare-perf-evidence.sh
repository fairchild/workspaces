#!/bin/bash
# Capture canonical before/after performance summaries and print PR-ready Markdown.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  ./scripts/prepare-perf-evidence.sh [options]

Options:
  --scenario <id>       Canonical scenario id. Default: debug_no_activate
  --output-dir <path>   Base output directory. Default: /tmp/workspaces-perf-evidence-<timestamp>
  --skip-before         Skip running the before capture and use --before-summary instead.
  --skip-after          Skip running the after capture and use --after-summary instead.
  --before-summary <p>  Existing before summary.json path.
  --after-summary <p>   Existing after summary.json path.
  -h, --help            Show this help text.
EOF
}

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONTRACT_PATH="$ROOT_DIR/config/performance/contract.json"
SCENARIO="debug_no_activate"
OUTPUT_DIR="/tmp/workspaces-perf-evidence-$(date +%Y%m%d-%H%M%S)"
SKIP_BEFORE=0
SKIP_AFTER=0
BEFORE_SUMMARY=""
AFTER_SUMMARY=""

validate_scenario() {
    python3 - "$CONTRACT_PATH" "$SCENARIO" <<'PY'
import json
import sys
from pathlib import Path

contract_path = Path(sys.argv[1])
scenario_id = sys.argv[2]
contract = json.loads(contract_path.read_text())
scenario_ids = {item["id"] for item in contract.get("scenarios", [])}

if scenario_id not in scenario_ids:
    joined = ", ".join(sorted(scenario_ids))
    print(f"Unknown scenario '{scenario_id}'. Valid scenarios: {joined}", file=sys.stderr)
    sys.exit(1)
PY
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --scenario)
            SCENARIO="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --skip-before)
            SKIP_BEFORE=1
            shift
            ;;
        --skip-after)
            SKIP_AFTER=1
            shift
            ;;
        --before-summary)
            BEFORE_SUMMARY="$2"
            shift 2
            ;;
        --after-summary)
            AFTER_SUMMARY="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unexpected argument: $1" >&2
            usage
            exit 1
            ;;
    esac
done

validate_scenario

mkdir -p "$OUTPUT_DIR"

run_capture() {
    local phase="$1"
    local phase_dir="$OUTPUT_DIR/$phase"
    local runner_log="$phase_dir/perf-runner.log"
    mkdir -p "$phase_dir"
    if ! "$ROOT_DIR/scripts/perf-runner.sh" --scenario "$SCENARIO" --output-dir "$phase_dir" >"$runner_log" 2>&1; then
        tail -n 120 "$runner_log" >&2 || true
        exit 1
    fi
    echo "$phase_dir/summary.json"
}

if [[ "$SKIP_BEFORE" -eq 0 ]]; then
    BEFORE_SUMMARY="$(run_capture before)"
fi

if [[ "$SKIP_AFTER" -eq 0 ]]; then
    AFTER_SUMMARY="$(run_capture after)"
fi

if [[ -z "$BEFORE_SUMMARY" || -z "$AFTER_SUMMARY" ]]; then
    echo "Both before and after summary paths are required." >&2
    exit 1
fi

if [[ ! -f "$BEFORE_SUMMARY" ]]; then
    echo "Before summary does not exist: $BEFORE_SUMMARY" >&2
    exit 1
fi

if [[ ! -f "$AFTER_SUMMARY" ]]; then
    echo "After summary does not exist: $AFTER_SUMMARY" >&2
    exit 1
fi

COMPARE_OUTPUT="$OUTPUT_DIR/compare.txt"
"$ROOT_DIR/scripts/perf-compare.py" "$BEFORE_SUMMARY" "$AFTER_SUMMARY" | tee "$COMPARE_OUTPUT"

cat <<EOF

PR-ready performance evidence:

- Scenario ID: \`$SCENARIO\`
- Before Summary: \`$BEFORE_SUMMARY\`
- After Summary: \`$AFTER_SUMMARY\`
- Delta Summary: summarize the key deltas from \`$COMPARE_OUTPUT\`

\`\`\`
$(cat "$COMPARE_OUTPUT")
\`\`\`

Workload / environment notes:
- Command source: \`./scripts/prepare-perf-evidence.sh --scenario $SCENARIO\`
- Compare summaries from the same machine and scenario whenever possible.
EOF
