#!/usr/bin/env bash
# ==========================================================================
# ui-state-golden.sh — verify or update structural UI-state goldens
# ==========================================================================
#
# Diffs the live `GET /v1/ui-state` read of a running (operator-scope) app —
# or a saved wire response — against fixtures/ui-state/<scenario>.json.
#
#   ./scripts/ui-state-golden.sh verify --scenario clean
#   ./scripts/ui-state-golden.sh verify --scenario clean --from-file wire.json
#   ./scripts/ui-state-golden.sh update --scenario clean      # EXPLICIT regeneration
#   ./scripts/ui-state-golden.sh print                        # dump live state JSON
#
# `update` is the only way a golden changes — a verify mismatch never rewrites
# anything. Comparison semantics are canonical in the unit-tested Swift
# comparator (Sources/WorkspaceManagerCore/Services/Automation/UIStateGolden.swift);
# the python below mirrors them for the live lane: compare the golden's `state`
# subtree against `.result.state`, after pruning the golden's `ignore` dot paths
# from both sides (arrays traverse element-wise). The wire `volatile` subtree is
# outside `state` and therefore never compared.
# ==========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CREDENTIAL_PATH="$HOME/Library/Application Support/com.cloudcompute.workspaces/automation-operator.json"

usage() {
  cat <<EOF
Usage: $(basename "$0") <verify|update|print> [options]

Options:
  --scenario <name>   Golden scenario id (fixtures/ui-state/<name>.json);
                      required for verify/update.
  --from-file <path>  Use a saved /v1/ui-state response instead of fetching
                      from the running app's automation socket.
  -h, --help          Show this help
EOF
  exit 1
}

COMMAND="${1:-}"
[[ -n "$COMMAND" ]] || usage
shift

SCENARIO=""
FROM_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenario) SCENARIO="$2"; shift 2 ;;
    --from-file) FROM_FILE="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "error: unknown option: $1" >&2; usage ;;
  esac
done

case "$COMMAND" in
  verify|update)
    [[ -n "$SCENARIO" ]] || { echo "error: --scenario is required for $COMMAND." >&2; usage; }
    ;;
  print) ;;
  *) echo "error: unknown command: $COMMAND" >&2; usage ;;
esac

GOLDEN_PATH="$REPO_ROOT/fixtures/ui-state/$SCENARIO.json"

# fetch_wire_response <out-file> — GET /v1/ui-state through the per-launch operator
# credential. Requires a running app launched with WORKSPACES_AUTOMATION_API=1 and
# WORKSPACES_AUTOMATION_OPERATOR=1 (the evidence lane's standard launch shape).
fetch_wire_response() {
  local out="$1"
  if [[ ! -f "$CREDENTIAL_PATH" ]]; then
    echo "error: no operator credential at:" >&2
    echo "       $CREDENTIAL_PATH" >&2
    echo "       Launch the app with operator scope first (the evidence lane does), or pass --from-file." >&2
    return 1
  fi
  local socket handle
  socket="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["socketPath"])' "$CREDENTIAL_PATH")"
  handle="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["handle"])' "$CREDENTIAL_PATH")"
  if ! curl --silent --show-error --fail-with-body \
      --unix-socket "$socket" \
      --header "x-workspaces-automation-handle: $handle" \
      "http://localhost/v1/ui-state" > "$out"; then
    echo "error: GET /v1/ui-state failed; response body (if any):" >&2
    cat "$out" >&2 || true
    return 1
  fi
}

WIRE_FILE="$FROM_FILE"
if [[ -z "$WIRE_FILE" ]]; then
  WIRE_FILE="$(mktemp -t ui-state-wire)"
  trap 'rm -f "$WIRE_FILE"' EXIT
  fetch_wire_response "$WIRE_FILE"
fi

case "$COMMAND" in
  print)
    python3 - "$WIRE_FILE" <<'PY'
import json, sys
wire = json.load(open(sys.argv[1]))
if not wire.get("ok"):
    sys.exit(f"error: /v1/ui-state returned an error envelope: {json.dumps(wire.get('error'))}")
print(json.dumps(wire["result"]["state"], indent=2, sort_keys=True))
PY
    ;;

  update)
    python3 - "$WIRE_FILE" "$GOLDEN_PATH" "$SCENARIO" <<'PY'
import json, os, sys
wire_path, golden_path, scenario = sys.argv[1:4]
wire = json.load(open(wire_path))
if not wire.get("ok"):
    sys.exit(f"error: /v1/ui-state returned an error envelope: {json.dumps(wire.get('error'))}")
ignore = []
if os.path.exists(golden_path):
    ignore = json.load(open(golden_path)).get("ignore", [])
document = {"scenario": scenario, "ignore": ignore, "state": wire["result"]["state"]}
with open(golden_path, "w") as handle:
    json.dump(document, handle, indent=2, sort_keys=True)
    handle.write("\n")
print(f"updated {golden_path}")
PY
    echo "→ re-verify offline: swift test --filter UIStateGolden" >&2
    ;;

  verify)
    [[ -f "$GOLDEN_PATH" ]] || { echo "error: no golden at $GOLDEN_PATH" >&2; exit 1; }
    python3 - "$WIRE_FILE" "$GOLDEN_PATH" <<'PY'
import json, sys
wire_path, golden_path = sys.argv[1:3]
wire = json.load(open(wire_path))
if not wire.get("ok"):
    sys.exit(f"error: /v1/ui-state returned an error envelope: {json.dumps(wire.get('error'))}")
golden = json.load(open(golden_path))


def prune(value, segments):
    if not segments:
        return value
    key = segments[0]
    if isinstance(value, dict):
        pruned = dict(value)
        if len(segments) == 1:
            pruned.pop(key, None)
        elif key in pruned:
            pruned[key] = prune(pruned[key], segments[1:])
        return pruned
    if isinstance(value, list):
        return [prune(element, segments) for element in value]
    return value


def diff(expected, actual, path, mismatches):
    if isinstance(expected, dict) and isinstance(actual, dict):
        for key in sorted(set(expected) | set(actual)):
            child = f"{path}.{key}"
            if key not in actual:
                mismatches.append(f"{child}: expected {json.dumps(expected[key], sort_keys=True)}, actual <absent>")
            elif key not in expected:
                mismatches.append(f"{child}: expected <absent>, actual {json.dumps(actual[key], sort_keys=True)}")
            else:
                diff(expected[key], actual[key], child, mismatches)
        return
    if isinstance(expected, list) and isinstance(actual, list):
        if len(expected) != len(actual):
            mismatches.append(f"{path}.count: expected {len(expected)}, actual {len(actual)}")
        for index, (left, right) in enumerate(zip(expected, actual)):
            diff(left, right, f"{path}[{index}]", mismatches)
        return
    if expected != actual or type(expected) is not type(actual):
        mismatches.append(
            f"{path}: expected {json.dumps(expected, sort_keys=True)}, actual {json.dumps(actual, sort_keys=True)}"
        )


expected_state = golden["state"]
actual_state = wire["result"]["state"]
for ignore_path in golden.get("ignore", []):
    segments = [segment for segment in ignore_path.split(".") if segment]
    expected_state = prune(expected_state, segments)
    actual_state = prune(actual_state, segments)

mismatches = []
diff(expected_state, actual_state, "state", mismatches)
if mismatches:
    print(f"✗ ui-state mismatch vs {golden_path}:", file=sys.stderr)
    for mismatch in sorted(mismatches):
        print(f"  {mismatch}", file=sys.stderr)
    print("  (goldens update only via: scripts/ui-state-golden.sh update --scenario <name>)", file=sys.stderr)
    sys.exit(1)
print(f"✓ ui-state matches {golden_path}")
PY
    ;;
esac
