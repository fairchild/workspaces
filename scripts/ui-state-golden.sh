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
#   ./scripts/ui-state-golden.sh settle --scenario clean      # print "<timeout> <poll>"
#
# `update` is the only way a golden changes — a verify mismatch never rewrites
# anything. Comparison semantics are canonical in the unit-tested Swift
# comparator (Sources/WorkspaceManagerCore/Services/Automation/UIStateGolden.swift);
# the python below mirrors them for the live lane: compare the golden's `state`
# subtree against `.result.state`, after pruning the golden's `ignore` dot paths
# from both sides (arrays traverse element-wise). The wire `volatile` subtree is
# outside `state` and therefore never compared.
#
# Key order: the golden mirrors the wire. `update` writes `state` exactly as the
# response delivered it and holds no opinion of its own, so an update against an
# unchanged app rewrites the same bytes and shows no diff. The response is already
# key-sorted (`AutomationJSON.encoder` sets `.sortedKeys`); re-sorting here would
# be a second, independent ordering that silently diverges if that ever changes.
# Only mismatch *messages* sort keys, where stable text matters and file shape
# does not.
#
# Settle: a golden may declare `"settle": {"timeoutSeconds": N, "pollSeconds": M}`
# for chrome that cannot exist at first paint (the orphan banner is decided by
# deferred startup work that runs seconds after the window renders). `verify`
# then re-fetches and re-compares on that interval until the state matches or the
# bound elapses — a per-golden wait, not a global sleep, and a deterministic
# failure when the state never arrives.
# ==========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CREDENTIAL_PATH="$HOME/Library/Application Support/com.cloudcompute.workspaces/automation-operator.json"

usage() {
  cat <<EOF
Usage: $(basename "$0") <verify|update|print|settle> [options]

Options:
  --scenario <name>   Golden scenario id (fixtures/ui-state/<name>.json);
                      required for verify/update/settle.
  --golden <path>     Use this golden file instead of the scenario's path
                      (tests and one-off comparisons).
  --from-file <path>  Use a saved /v1/ui-state response instead of fetching
                      from the running app's automation socket. A saved
                      response cannot change, so any declared settle is skipped.
  -h, --help          Show this help
EOF
  exit 1
}

COMMAND="${1:-}"
[[ -n "$COMMAND" ]] || usage
shift

SCENARIO=""
FROM_FILE=""
GOLDEN_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenario) SCENARIO="$2"; shift 2 ;;
    --golden) GOLDEN_OVERRIDE="$2"; shift 2 ;;
    --from-file) FROM_FILE="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "error: unknown option: $1" >&2; usage ;;
  esac
done

case "$COMMAND" in
  verify|update|settle)
    if [[ -z "$SCENARIO" && -z "$GOLDEN_OVERRIDE" ]]; then
      echo "error: --scenario (or --golden) is required for $COMMAND." >&2
      usage
    fi
    ;;
  print) ;;
  *) echo "error: unknown command: $COMMAND" >&2; usage ;;
esac

GOLDEN_PATH="${GOLDEN_OVERRIDE:-$REPO_ROOT/fixtures/ui-state/$SCENARIO.json}"

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

# acquire_wire <out-file> — the saved response when --from-file was given, a live
# fetch otherwise.
acquire_wire() {
  if [[ -n "$FROM_FILE" ]]; then
    cp "$FROM_FILE" "$1"
    return 0
  fi
  fetch_wire_response "$1"
}

# read_settle — prints "<timeoutSeconds> <pollSeconds>" for the golden's settle
# declaration, "0 0" when it declares none. Validates the shape here, where it is
# used, so a typo fails loudly instead of silently disabling the wait.
read_settle() {
  python3 - "$GOLDEN_PATH" <<'PY'
import json, sys

golden_path = sys.argv[1]
settle = json.load(open(golden_path)).get("settle")
if settle is None:
    print("0 0")
    raise SystemExit(0)
if not isinstance(settle, dict):
    raise SystemExit(f"error: golden 'settle' must be an object in {golden_path}")
timeout = settle.get("timeoutSeconds")
poll = settle.get("pollSeconds", 1)
for name, value in (("timeoutSeconds", timeout), ("pollSeconds", poll)):
    if not isinstance(value, int) or isinstance(value, bool) or value < 1:
        raise SystemExit(f"error: golden settle '{name}' must be an integer >= 1 in {golden_path}")
print(timeout, poll)
PY
}

# compare_wire <wire-file> <quiet|loud> — exit 0 on match, 1 on mismatch. Loud mode
# prints the path-sorted mismatch list; quiet mode is the retry-loop's probe.
compare_wire() {
  python3 - "$1" "$GOLDEN_PATH" "$2" <<'PY'
import json, sys
wire_path, golden_path, report = sys.argv[1:4]
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
    if report == "loud":
        print(f"✗ ui-state mismatch vs {golden_path}:", file=sys.stderr)
        for mismatch in sorted(mismatches):
            print(f"  {mismatch}", file=sys.stderr)
        print("  (goldens update only via: scripts/ui-state-golden.sh update --scenario <name>)", file=sys.stderr)
    sys.exit(1)
if report == "loud":
    print(f"✓ ui-state matches {golden_path}")
PY
}

case "$COMMAND" in
  settle)
    [[ -f "$GOLDEN_PATH" ]] || { echo "error: no golden at $GOLDEN_PATH" >&2; exit 1; }
    read_settle
    ;;

  print)
    WIRE_FILE="$(mktemp "${TMPDIR:-/tmp}/ui-state-wire.XXXXXX")"
    trap 'rm -f "$WIRE_FILE"' EXIT
    acquire_wire "$WIRE_FILE"
    python3 - "$WIRE_FILE" <<'PY'
import json, sys
wire = json.load(open(sys.argv[1]))
if not wire.get("ok"):
    sys.exit(f"error: /v1/ui-state returned an error envelope: {json.dumps(wire.get('error'))}")
print(json.dumps(wire["result"]["state"], indent=2))
PY
    ;;

  update)
    WIRE_FILE="$(mktemp "${TMPDIR:-/tmp}/ui-state-wire.XXXXXX")"
    trap 'rm -f "$WIRE_FILE"' EXIT
    acquire_wire "$WIRE_FILE"
    python3 - "$WIRE_FILE" "$GOLDEN_PATH" "${SCENARIO:-}" <<'PY'
import json, os, sys
wire_path, golden_path, scenario = sys.argv[1:4]
wire = json.load(open(wire_path))
if not wire.get("ok"):
    sys.exit(f"error: /v1/ui-state returned an error envelope: {json.dumps(wire.get('error'))}")

# Carried forward, never regenerated: the ignore list and the settle declaration are
# authored decisions about the golden, not observations of the app.
existing = json.load(open(golden_path)) if os.path.exists(golden_path) else {}
document = {"scenario": scenario or existing.get("scenario", ""), "ignore": existing.get("ignore", [])}
if "settle" in existing:
    document["settle"] = existing["settle"]
document["state"] = wire["result"]["state"]

with open(golden_path, "w") as handle:
    json.dump(document, handle, indent=2)
    handle.write("\n")
print(f"updated {golden_path}")
PY
    echo "→ re-verify offline: swift test --filter UIStateGolden" >&2
    ;;

  verify)
    [[ -f "$GOLDEN_PATH" ]] || { echo "error: no golden at $GOLDEN_PATH" >&2; exit 1; }
    WIRE_FILE="$(mktemp "${TMPDIR:-/tmp}/ui-state-wire.XXXXXX")"
    trap 'rm -f "$WIRE_FILE"' EXIT

    # Separate assignment, not `read <<<"$(…)"`: `read` would mask a malformed
    # declaration's non-zero exit and silently verify with no wait at all.
    SETTLE_SPEC="$(read_settle)"
    read -r SETTLE_TIMEOUT SETTLE_POLL <<<"$SETTLE_SPEC"
    if [[ -n "$FROM_FILE" && "$SETTLE_TIMEOUT" != "0" ]]; then
      echo "note: --from-file is a fixed response; the golden's ${SETTLE_TIMEOUT}s settle does not apply." >&2
      SETTLE_TIMEOUT=0
    fi

    if [[ "$SETTLE_TIMEOUT" == "0" ]]; then
      acquire_wire "$WIRE_FILE"
      compare_wire "$WIRE_FILE" loud
      exit 0
    fi

    echo "→ settling: this golden allows up to ${SETTLE_TIMEOUT}s (polling every ${SETTLE_POLL}s) for the state to arrive." >&2
    waited=0
    while :; do
      acquire_wire "$WIRE_FILE"
      if compare_wire "$WIRE_FILE" quiet; then
        compare_wire "$WIRE_FILE" loud
        if (( waited > 0 )); then
          echo "  (settled after ${waited}s)" >&2
        fi
        exit 0
      fi
      if (( waited + SETTLE_POLL > SETTLE_TIMEOUT )); then
        compare_wire "$WIRE_FILE" loud || true
        echo "error: ui-state never settled to $GOLDEN_PATH within ${SETTLE_TIMEOUT}s" >&2
        echo "       (polled every ${SETTLE_POLL}s; the mismatch above is the final read)." >&2
        exit 1
      fi
      sleep "$SETTLE_POLL"
      waited=$((waited + SETTLE_POLL))
    done
    ;;
esac
