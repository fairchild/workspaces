#!/bin/bash
# Shared helpers for standalone Lume validation flows.

set -euo pipefail

LUME_STANDALONE_DEFAULT_OUTPUT_ROOT="${LUME_STANDALONE_DEFAULT_OUTPUT_ROOT:-$REPO_ROOT/output/lume-standalone}"
LUME_STANDALONE_DEFAULT_BASE_PREP_TIMEOUT_SECONDS="${LUME_STANDALONE_DEFAULT_BASE_PREP_TIMEOUT_SECONDS:-21600}"
LUME_STANDALONE_DEFAULT_BASE_READY_TIMEOUT_SECONDS="${LUME_STANDALONE_DEFAULT_BASE_READY_TIMEOUT_SECONDS:-2700}"
LUME_STANDALONE_DEFAULT_CLONE_READY_TIMEOUT_SECONDS="${LUME_STANDALONE_DEFAULT_CLONE_READY_TIMEOUT_SECONDS:-1800}"
LUME_STANDALONE_DEFAULT_PREPARING_SLEEP_SECONDS="${LUME_STANDALONE_DEFAULT_PREPARING_SLEEP_SECONDS:-60}"
LUME_STANDALONE_DEFAULT_RUNNING_SLEEP_SECONDS="${LUME_STANDALONE_DEFAULT_RUNNING_SLEEP_SECONDS:-15}"
LUME_STANDALONE_DEFAULT_PREPARE_RETRIES="${LUME_STANDALONE_DEFAULT_PREPARE_RETRIES:-3}"
LUME_STANDALONE_MIN_FREE_GB="${LUME_STANDALONE_MIN_FREE_GB:-70}"
export LUME_STANDALONE_RUN_NETWORK="${LUME_STANDALONE_RUN_NETWORK:-nat}"
export LUME_STANDALONE_PREPARE_NETWORK="${LUME_STANDALONE_PREPARE_NETWORK:-$LUME_STANDALONE_RUN_NETWORK}"
LUME_STANDALONE_SSH_USER="${LUME_STANDALONE_SSH_USER:-lume}"
LUME_STANDALONE_SSH_PASSWORD="${LUME_STANDALONE_SSH_PASSWORD:-${LUME_GUEST_PASSWORD:-}}"

lume_standalone_log() {
    echo "[$(date +%H:%M:%S)] $*"
}

lume_standalone_fail() {
    local message="$1"
    echo "ERROR: $message" >&2
    return 1
}

lume_standalone_require_guest_password() {
    if [[ -n "$LUME_STANDALONE_SSH_PASSWORD" ]]; then
        return
    fi
    lume_standalone_fail \
        "Set LUME_GUEST_PASSWORD (or LUME_STANDALONE_SSH_PASSWORD) before provisioning or probing Lume guests."
}

lume_standalone_iso8601_now() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

lume_standalone_output_root() {
    echo "${LUME_STANDALONE_OUTPUT_ROOT:-$LUME_STANDALONE_DEFAULT_OUTPUT_ROOT}"
}

lume_standalone_setup_run_dir() {
    local provided_run_dir="${1:-}"
    local timestamp
    timestamp="$(date +%Y%m%d-%H%M%S)"

    if [[ -n "$provided_run_dir" ]]; then
        export LUME_STANDALONE_RUN_DIR="$provided_run_dir"
        export LUME_STANDALONE_TIMESTAMP="$(basename "$provided_run_dir")"
    else
        export LUME_STANDALONE_TIMESTAMP="$timestamp"
        export LUME_STANDALONE_RUN_DIR="$(lume_standalone_output_root)/$timestamp"
    fi

    mkdir -p "$(lume_standalone_output_root)"
    mkdir -p "$LUME_STANDALONE_RUN_DIR"
    ln -sfn "$LUME_STANDALONE_RUN_DIR" "$(lume_standalone_output_root)/latest"
}

lume_standalone_require_lume() {
    if [[ -n "${LUME_BIN:-}" && -x "${LUME_BIN:-}" ]]; then
        return
    fi

    local candidate
    for candidate in \
        "${HOME}/.local/bin/lume" \
        "/opt/homebrew/bin/lume" \
        "/usr/local/bin/lume" \
        "$(command -v lume 2>/dev/null || true)"
    do
        if [[ -n "$candidate" && -x "$candidate" ]]; then
            export LUME_BIN="$candidate"
            return
        fi
    done

    lume_standalone_fail "Could not find an executable `lume` binary."
}

lume_standalone_daemon_base_url() {
    if [[ -n "${LUME_STANDALONE_DAEMON_BASE_URL:-}" ]]; then
        echo "$LUME_STANDALONE_DAEMON_BASE_URL"
        return
    fi

    if /usr/bin/curl --silent --show-error --fail \
        --max-time 2 \
        "http://127.0.0.1:7778/lume/host/status" \
        >/dev/null 2>&1
    then
        echo "http://127.0.0.1:7778/lume"
        return
    fi

    echo "http://127.0.0.1:7777/lume"
}

lume_standalone_base_metadata_dir() {
    echo "${LUME_STANDALONE_BASE_METADATA_DIR:-$HOME/Library/Application Support/WorkspaceManager/LumeValidatedBases}"
}

lume_standalone_storage_root() {
    echo "${LUME_STANDALONE_STORAGE_ROOT:-$HOME/Library/Application Support/WorkspaceManager/LumeStorage}"
}

lume_standalone_legacy_storage_root() {
    echo "${LUME_STANDALONE_LEGACY_STORAGE_ROOT:-$HOME/.lume}"
}

lume_standalone_marker_path() {
    local vm_name="$1"
    echo "$(lume_standalone_base_metadata_dir)/${vm_name}.json"
}

lume_standalone_status_path() {
    echo "$LUME_STANDALONE_RUN_DIR/status.json"
}

lume_standalone_sanitize_component() {
    python3 - "$1" <<'PY'
import re
import sys

value = sys.argv[1].lower().replace(" ", "-")
value = re.sub(r"[^a-z0-9-]", "-", value)
value = re.sub(r"-+", "-", value).strip("-")
print(value or "base")
PY
}

lume_standalone_detect_host_profile() {
    local architecture macos_version macos_major xcode_version
    architecture="$(uname -m)"
    [[ "$architecture" == "arm64" ]] || lume_standalone_fail "Lume validation requires Apple Silicon."

    macos_version="$(/usr/bin/sw_vers -productVersion)"
    macos_major="${macos_version%%.*}"

    case "$macos_major" in
        26) LUME_STANDALONE_MACOS_FAMILY="tahoe" ;;
        15) LUME_STANDALONE_MACOS_FAMILY="sequoia" ;;
        14) LUME_STANDALONE_MACOS_FAMILY="sonoma" ;;
        *) lume_standalone_fail "Unsupported macOS version for Lume validation: $macos_version" ;;
    esac

    xcode_version="$(
        /usr/bin/xcodebuild -version 2>/dev/null | awk '/^Xcode / { print $2; exit }'
    )"

    export LUME_STANDALONE_ARCHITECTURE="$architecture"
    export LUME_STANDALONE_MACOS_VERSION="$macos_version"
    export LUME_STANDALONE_XCODE_VERSION="${xcode_version:-}"
    export LUME_STANDALONE_HOST_PROFILE_KEY="${LUME_STANDALONE_MACOS_FAMILY}-${macos_version}"
    if [[ -n "${LUME_STANDALONE_XCODE_VERSION:-}" ]]; then
        export LUME_STANDALONE_HOST_PROFILE_KEY="${LUME_STANDALONE_HOST_PROFILE_KEY}-xcode-${LUME_STANDALONE_XCODE_VERSION}"
    fi

    local display_name family_label
    case "$LUME_STANDALONE_MACOS_FAMILY" in
        tahoe) family_label="Tahoe" ;;
        sequoia) family_label="Sequoia" ;;
        sonoma) family_label="Sonoma" ;;
    esac
    display_name="${family_label} ${LUME_STANDALONE_MACOS_VERSION}"
    if [[ -n "${LUME_STANDALONE_XCODE_VERSION:-}" ]]; then
        display_name="${display_name} + Xcode ${LUME_STANDALONE_XCODE_VERSION}"
    fi
    export LUME_STANDALONE_HOST_PROFILE_DISPLAY_NAME="$display_name"

    local sanitized_profile_key
    sanitized_profile_key="$(lume_standalone_sanitize_component "$LUME_STANDALONE_HOST_PROFILE_KEY")"
    export LUME_STANDALONE_BASE_VM_NAME="workspaces-validated-base-macos-${sanitized_profile_key}"
    export LUME_STANDALONE_BASE_STORAGE_PATH="$(lume_standalone_storage_root)/validated-bases"
    export LUME_STANDALONE_SMOKE_STORAGE_PATH="$(lume_standalone_storage_root)/standalone-smoke"
}

lume_standalone_resolve_image() {
    export LUME_STANDALONE_BASE_SOURCE="stock-prepare"
    export LUME_STANDALONE_SOURCE_KIND="stockPrepared"
    export LUME_STANDALONE_IMAGE_REFERENCE=""

    case "${LUME_STANDALONE_MACOS_FAMILY:-}" in
        tahoe)
            if [[ -z "${LUME_STANDALONE_XCODE_VERSION:-}" || "${LUME_STANDALONE_XCODE_VERSION}" == "26.2" ]]; then
                LUME_STANDALONE_IMAGE_REFERENCE="macos-tahoe-xcode:26.2"
            elif [[ "${LUME_STANDALONE_XCODE_VERSION}" == "26.0" ]]; then
                LUME_STANDALONE_IMAGE_REFERENCE="macos-tahoe-xcode:26.0"
            else
                LUME_STANDALONE_IMAGE_REFERENCE="macos-tahoe-xcode:26.2"
            fi
            ;;
        sequoia)
            LUME_STANDALONE_IMAGE_REFERENCE="macos-sequoia-xcode:16.4"
            ;;
        *)
            LUME_STANDALONE_IMAGE_REFERENCE=""
            ;;
    esac

    if [[ -n "$LUME_STANDALONE_IMAGE_REFERENCE" ]]; then
        export LUME_STANDALONE_BASE_SOURCE="registry"
        export LUME_STANDALONE_SOURCE_KIND="pulledImage"
    fi
}

lume_standalone_legacy_base_vm_name() {
    local xcode_component=""
    if [[ -n "${LUME_STANDALONE_XCODE_VERSION:-}" ]]; then
        xcode_component="-xcode-$(lume_standalone_sanitize_component "$LUME_STANDALONE_XCODE_VERSION")"
    fi
    echo "workspaces-base-macos-macos-${LUME_STANDALONE_MACOS_FAMILY}${xcode_component}"
}

lume_standalone_legacy_base_exists() {
    local legacy_name
    legacy_name="$(lume_standalone_legacy_base_vm_name)"
    "$LUME_BIN" get "$legacy_name" --storage "$(lume_standalone_legacy_storage_root)" -f json >/dev/null 2>&1
}

lume_standalone_import_legacy_base() {
    local legacy_name
    legacy_name="$(lume_standalone_legacy_base_vm_name)"

    lume_standalone_legacy_base_exists || return 1

    if "$LUME_BIN" get "$LUME_STANDALONE_BASE_VM_NAME" --storage "$LUME_STANDALONE_BASE_STORAGE_PATH" -f json >/dev/null 2>&1; then
        lume_standalone_remove_vm "$LUME_STANDALONE_BASE_VM_NAME" "$LUME_STANDALONE_BASE_STORAGE_PATH"
    fi

    if [[ -n "$(lume_standalone_vm_dir_path "$LUME_STANDALONE_BASE_VM_NAME" "$LUME_STANDALONE_BASE_STORAGE_PATH")" ]]; then
        lume_standalone_move_stale_vm_dir "$LUME_STANDALONE_BASE_VM_NAME" "$LUME_STANDALONE_BASE_STORAGE_PATH"
    fi

    "$LUME_BIN" clone "$legacy_name" "$LUME_STANDALONE_BASE_VM_NAME" \
        --source-storage "$(lume_standalone_legacy_storage_root)" \
        --dest-storage "$LUME_STANDALONE_BASE_STORAGE_PATH"
}

lume_standalone_resolve_unattended_config() {
    local network_profile versioned_override_path default_override_path
    network_profile=""
    case "${LUME_STANDALONE_PREPARE_NETWORK:-}" in
        bridged:*) network_profile="bridged" ;;
        nat) network_profile="nat" ;;
    esac
    versioned_override_path="$(
        python3 - "$REPO_ROOT/config/lume/unattended" "${LUME_STANDALONE_MACOS_FAMILY}" "$network_profile" <<'PY'
from pathlib import Path
import re
import sys

directory = Path(sys.argv[1])
family = sys.argv[2]
network_profile = sys.argv[3]

patterns = []
if network_profile:
    patterns.append(
        re.compile(rf"^{re.escape(family)}-workspaces-{re.escape(network_profile)}-v(\d+)\.yml$")
    )
patterns.append(re.compile(rf"^{re.escape(family)}-workspaces-v(\d+)\.yml$"))

for pattern in patterns:
    matches = []
    for path in directory.iterdir():
        if not path.is_file():
            continue
        match = pattern.match(path.name)
        if not match:
            continue
        matches.append((int(match.group(1)), path))

    if matches:
        matches.sort()
        print(matches[-1][1])
        break
PY
    )"
    default_override_path="$REPO_ROOT/config/lume/unattended/${LUME_STANDALONE_MACOS_FAMILY}-workspaces.yml"

    if [[ -n "${LUME_STANDALONE_UNATTENDED_CONFIG_PATH:-}" ]]; then
        local configured_path="$LUME_STANDALONE_UNATTENDED_CONFIG_PATH"
        if [[ ! -f "$LUME_STANDALONE_UNATTENDED_CONFIG_PATH" ]]; then
            lume_standalone_fail \
                "Configured unattended profile does not exist: $LUME_STANDALONE_UNATTENDED_CONFIG_PATH"
        fi
        if grep -q "__LUME_GUEST_PASSWORD__" "$LUME_STANDALONE_UNATTENDED_CONFIG_PATH"; then
            lume_standalone_require_guest_password
            LUME_STANDALONE_UNATTENDED_CONFIG_PATH="$(
                "$REPO_ROOT/scripts/render-lume-unattended-config.sh" "$LUME_STANDALONE_UNATTENDED_CONFIG_PATH"
            )"
        fi
        export LUME_STANDALONE_UNATTENDED_CONFIG_PATH
        export LUME_STANDALONE_UNATTENDED_CONFIG_LABEL="${LUME_STANDALONE_UNATTENDED_CONFIG_LABEL:-$configured_path}"
        return
    fi

    if [[ -n "$versioned_override_path" ]]; then
        export LUME_STANDALONE_UNATTENDED_CONFIG_PATH="$versioned_override_path"
        if grep -q "__LUME_GUEST_PASSWORD__" "$LUME_STANDALONE_UNATTENDED_CONFIG_PATH"; then
            lume_standalone_require_guest_password
            export LUME_STANDALONE_UNATTENDED_CONFIG_PATH="$(
                "$REPO_ROOT/scripts/render-lume-unattended-config.sh" "$LUME_STANDALONE_UNATTENDED_CONFIG_PATH"
            )"
        fi
        export LUME_STANDALONE_UNATTENDED_CONFIG_LABEL="config/lume/unattended/$(basename "$versioned_override_path")"
        return
    fi

    if [[ -f "$default_override_path" ]]; then
        export LUME_STANDALONE_UNATTENDED_CONFIG_PATH="$default_override_path"
        if grep -q "__LUME_GUEST_PASSWORD__" "$LUME_STANDALONE_UNATTENDED_CONFIG_PATH"; then
            lume_standalone_require_guest_password
            export LUME_STANDALONE_UNATTENDED_CONFIG_PATH="$(
                "$REPO_ROOT/scripts/render-lume-unattended-config.sh" "$LUME_STANDALONE_UNATTENDED_CONFIG_PATH"
            )"
        fi
        export LUME_STANDALONE_UNATTENDED_CONFIG_LABEL="config/lume/unattended/$(basename "$default_override_path")"
        return
    fi

    export LUME_STANDALONE_UNATTENDED_CONFIG_PATH="$LUME_STANDALONE_MACOS_FAMILY"
    export LUME_STANDALONE_UNATTENDED_CONFIG_LABEL="preset:$LUME_STANDALONE_MACOS_FAMILY"
}

lume_standalone_marker_is_valid() {
    local marker_path="$1"
    [[ -f "$marker_path" ]] || return 1

    python3 - "$marker_path" "${LUME_STANDALONE_HOST_PROFILE_KEY}" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
profile_key = sys.argv[2]
try:
    payload = json.loads(path.read_text())
except Exception:
    raise SystemExit(1)

valid = (
    payload.get("state") == "ready"
    and payload.get("hostProfileKey") == profile_key
    and bool(payload.get("validatedAt"))
)
raise SystemExit(0 if valid else 1)
PY
}

lume_standalone_marker_state() {
    local marker_path="$1"
    [[ -f "$marker_path" ]] || return 0

    python3 - "$marker_path" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    payload = json.loads(path.read_text())
except Exception:
    print("")
    raise SystemExit(0)

print(payload.get("state") or "")
PY
}

lume_standalone_marker_field() {
    local marker_path="$1"
    local field_name="$2"
    [[ -f "$marker_path" ]] || return 0

    python3 - "$marker_path" "$field_name" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
field = sys.argv[2]
try:
    payload = json.loads(path.read_text())
except Exception:
    raise SystemExit(0)

value = payload.get(field)
if value is None:
    raise SystemExit(0)
print(value)
PY
}

lume_standalone_write_marker() {
    local vm_name="$1"
    local validation_state="$2"
    local failure_message="${3:-}"
    local marker_path
    marker_path="$(lume_standalone_marker_path "$vm_name")"
    mkdir -p "$(dirname "$marker_path")"

    python3 - "$marker_path" <<'PY'
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = {}
if path.exists():
    try:
        payload = json.loads(path.read_text())
    except Exception:
        payload = {}

payload = {
    "schemaVersion": 1,
    "vmName": os.environ["LUME_STANDALONE_BASE_VM_NAME"],
    "hostProfileKey": os.environ["LUME_STANDALONE_HOST_PROFILE_KEY"],
    "storagePath": os.environ["LUME_STANDALONE_BASE_STORAGE_PATH"],
    "sourceKind": os.environ.get("LUME_STANDALONE_SOURCE_KIND") or payload.get("sourceKind"),
    "imageReference": os.environ.get("LUME_STANDALONE_IMAGE_REFERENCE") or payload.get("imageReference"),
    "state": os.environ["LUME_STANDALONE_MARKER_VALIDATION_STATE"],
    "validatedAt": os.environ.get("LUME_STANDALONE_MARKER_VALIDATED_AT"),
    "failureStage": None if os.environ["LUME_STANDALONE_MARKER_VALIDATION_STATE"] == "ready" else (os.environ.get("LUME_STANDALONE_STATUS_FAILURE_STAGE") or None),
    "failureMessage": os.environ.get("LUME_STANDALONE_MARKER_FAILURE_MESSAGE") or None,
    "unattendedConfig": os.environ.get("LUME_STANDALONE_UNATTENDED_CONFIG_LABEL") or None,
    "validationSource": "standalone-lume-validation",
}

path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
PY
}

lume_standalone_set_status() {
    local status_path
    status_path="$(lume_standalone_status_path)"
    mkdir -p "$(dirname "$status_path")"

    python3 - "$status_path" <<'PY'
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = {}
if path.exists():
    try:
        payload = json.loads(path.read_text())
    except Exception:
        payload = {}

payload.update(
    {
        "hostProfile": os.environ.get("LUME_STANDALONE_HOST_PROFILE_KEY", ""),
        "baseVMName": os.environ.get("LUME_STANDALONE_BASE_VM_NAME", ""),
        "storagePath": os.environ.get("LUME_STANDALONE_BASE_STORAGE_PATH", ""),
        "baseState": os.environ.get("LUME_STANDALONE_STATUS_BASE_STATE", "missing"),
        "baseSource": os.environ.get("LUME_STANDALONE_STATUS_BASE_SOURCE", ""),
        "baseVerifiedAt": os.environ.get("LUME_STANDALONE_STATUS_BASE_VERIFIED_AT") or None,
        "cloneState": os.environ.get("LUME_STANDALONE_STATUS_CLONE_STATE", "not_run"),
        "unattendedConfig": os.environ.get("LUME_STANDALONE_UNATTENDED_CONFIG_LABEL") or None,
        "unattendedDebugDir": os.environ.get("LUME_STANDALONE_UNATTENDED_DEBUG_DIR") or None,
        "failureStage": os.environ.get("LUME_STANDALONE_STATUS_FAILURE_STAGE") or None,
        "failureMessage": os.environ.get("LUME_STANDALONE_STATUS_FAILURE_MESSAGE") or None,
    }
)

path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
PY
}

lume_standalone_json_field() {
    local json_file="$1"
    local path="$2"
    python3 - "$json_file" "$path" <<'PY'
import json
import sys
from pathlib import Path

try:
    data = json.loads(Path(sys.argv[1]).read_text())
    cursor = data
    for part in sys.argv[2].split("."):
        if isinstance(cursor, list):
            cursor = cursor[int(part)]
        else:
            cursor = cursor.get(part)
        if cursor is None:
            break
except Exception:
    cursor = None

if cursor is None:
    print("")
elif isinstance(cursor, bool):
    print("true" if cursor else "false")
else:
    print(cursor)
PY
}

lume_standalone_daemon_get_vm() {
    local vm_name="$1"
    local storage_path="$2"
    local output_path="$3"
    local url
    url="$(python3 - "$vm_name" "$storage_path" "$(lume_standalone_daemon_base_url)" <<'PY'
import sys
from urllib.parse import urlencode

base = sys.argv[3].rstrip("/") + "/vms/" + sys.argv[1]
storage = sys.argv[2]
if storage:
    print(base + "?" + urlencode({"storage": storage}))
else:
    print(base)
PY
)"
    /usr/bin/curl --silent --show-error --fail \
        "$url" \
        >"$output_path"
}

lume_standalone_daemon_run_vm() {
    local vm_name="$1"
    local storage_path="$2"
    local shared_dir="${3:-}"
    local output_path="$4"
    python3 - "$vm_name" "$storage_path" "$shared_dir" "$(lume_standalone_daemon_base_url)" "$LUME_STANDALONE_RUN_NETWORK" <<'PY' | /usr/bin/curl --silent --show-error --fail \
        --header 'Content-Type: application/json' \
        --data-binary @- \
        "$(python3 - "$vm_name" "$(lume_standalone_daemon_base_url)" <<'PY2'
import sys

print(sys.argv[2].rstrip("/") + "/vms/" + sys.argv[1] + "/run")
PY2
)" >"$output_path"
import json
import sys

payload = {
    "storage": sys.argv[2],
    "noDisplay": True,
    "network": sys.argv[5],
}

if sys.argv[3]:
    payload["sharedDirectories"] = [
        {
            "hostPath": sys.argv[3],
            "readOnly": False,
        }
    ]

print(json.dumps(payload))
PY
}

lume_standalone_start_cli_vm() {
    local vm_name="$1"
    local storage_path="$2"
    local shared_dir="$3"
    local output_path="$4"
    local pid_path="${5:-}"

    python3 - "$LUME_BIN" "$vm_name" "$storage_path" "$shared_dir" "$output_path" "$LUME_STANDALONE_RUN_NETWORK" "$pid_path" <<'PY'
import subprocess
import sys
from pathlib import Path

lume_bin, vm_name, storage_path, shared_dir, output_path, network_mode, pid_path = sys.argv[1:]

cmd = [
    lume_bin,
    "run",
    vm_name,
    "--storage",
    storage_path,
    "--network",
    network_mode,
    "--no-display",
]
if shared_dir:
    cmd.extend(["--shared-dir", shared_dir])

output = Path(output_path)
output.parent.mkdir(parents=True, exist_ok=True)
with output.open("ab") as stream:
    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.DEVNULL,
        stdout=stream,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )

if pid_path:
    Path(pid_path).write_text(f"{proc.pid}\n")
PY
}

lume_standalone_direct_ssh() {
    local host="$1"
    local command="$2"
    local output_path="$3"

    lume_standalone_require_guest_password

    /usr/bin/expect <<'EXPECT' >"$output_path" 2>&1
set timeout 120
set host $env(LUME_STANDALONE_DIRECT_SSH_HOST)
set user $env(LUME_STANDALONE_SSH_USER)
set password $env(LUME_STANDALONE_SSH_PASSWORD)
set cmd $env(LUME_STANDALONE_DIRECT_SSH_COMMAND)

spawn /usr/bin/ssh \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout=20 \
  -o PreferredAuthentications=password \
  -o PubkeyAuthentication=no \
  ${user}@${host} sh -lc $cmd

expect {
  -re "(?i)are you sure you want to continue connecting" {
    send "yes\r"
    exp_continue
  }
  -re "(?i)password:" {
    send "$password\r"
    exp_continue
  }
  eof {
    catch wait result
    set exit_status [lindex $result 3]
    exit $exit_status
  }
}
EXPECT
}

lume_standalone_write_vm_snapshot() {
    local output_path="$1"
    local vm_name="$2"
    local status="$3"
    local ip_address="$4"
    local ssh_available="$5"
    local vnc_url="${6:-}"

    python3 - "$output_path" "$vm_name" "$status" "$ip_address" "$ssh_available" "$vnc_url" <<'PY'
import json
import sys
from pathlib import Path

output_path = Path(sys.argv[1])
vm_name, status, ip_address, ssh_available, vnc_url = sys.argv[2:]

payload = {}
if output_path.exists():
    try:
        payload = json.loads(output_path.read_text())
    except Exception:
        payload = {}

if not isinstance(payload, dict):
    payload = {}

payload["name"] = vm_name
payload["status"] = status if status and status != "null" else None
payload["ipAddress"] = ip_address if ip_address and ip_address != "null" else None
payload["sshAvailable"] = ssh_available if ssh_available and ssh_available != "null" else None
if vnc_url and vnc_url != "null":
    payload["vncUrl"] = vnc_url

output_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
PY
}

lume_standalone_exec_remote() {
    local vm_name="$1"
    local storage_path="$2"
    local host="$3"
    local command="$4"
    local output_path="$5"

    lume_standalone_require_guest_password

    if "$LUME_BIN" ssh \
        "$vm_name" \
        --storage "$storage_path" \
        --user "$LUME_STANDALONE_SSH_USER" \
        --password "$LUME_STANDALONE_SSH_PASSWORD" \
        --timeout 120 \
        "$command" \
        >"$output_path" 2>&1
    then
        return 0
    fi

    if [[ -n "$host" && "$host" != "null" ]]; then
        LUME_STANDALONE_DIRECT_SSH_HOST="$host" \
        LUME_STANDALONE_SSH_USER="$LUME_STANDALONE_SSH_USER" \
        LUME_STANDALONE_SSH_PASSWORD="$LUME_STANDALONE_SSH_PASSWORD" \
        LUME_STANDALONE_DIRECT_SSH_COMMAND="$command" \
        lume_standalone_direct_ssh "$host" "$command" "$output_path"
        return $?
    fi

    return 1
}

lume_standalone_cli_get_vm() {
    local vm_name="$1"
    local storage_path="$2"
    local output_path="$3"
    if [[ -n "$storage_path" ]]; then
        "$LUME_BIN" get "$vm_name" --storage "$storage_path" -f json >"$output_path"
    else
        "$LUME_BIN" get "$vm_name" -f json >"$output_path"
    fi
}

lume_standalone_vm_dir_path() {
    local vm_name="$1"
    local storage_path="$2"
    if [[ -d "$storage_path/$vm_name" ]]; then
        echo "$storage_path/$vm_name"
    else
        echo ""
    fi
}

lume_standalone_move_stale_vm_dir() {
    local vm_name="$1"
    local storage_path="$2"
    local stale_path
    stale_path="$(lume_standalone_vm_dir_path "$vm_name" "$storage_path")"
    [[ -n "$stale_path" ]] || return 0

    local archived_path="$LUME_STANDALONE_RUN_DIR/${vm_name}.stale.$(date +%Y%m%d-%H%M%S)"
    mv "$stale_path" "$archived_path"
    lume_standalone_log "Moved stale VM directory aside: $archived_path"
}

lume_standalone_remove_vm() {
    local vm_name="$1"
    local storage_path="$2"
    "$LUME_BIN" stop "$vm_name" --storage "$storage_path" >/dev/null 2>&1 || true
    "$LUME_BIN" delete "$vm_name" --storage "$storage_path" --force >/dev/null 2>&1 || true
}

lume_standalone_copy_daemon_logs() {
    [[ -f /tmp/lume_daemon.log ]] && cp /tmp/lume_daemon.log "$LUME_STANDALONE_RUN_DIR/daemon.log"
    [[ -f /tmp/lume_daemon.error.log ]] && cp /tmp/lume_daemon.error.log "$LUME_STANDALONE_RUN_DIR/daemon.error.log"
}

lume_standalone_free_gb_for_path() {
    local target_path="$1"
    df -g "$target_path" | awk 'NR==2 { print $4 }'
}

lume_standalone_vm_mac_address() {
    local vm_name="$1"
    local storage_path="$2"
    local config_path="$storage_path/$vm_name/config.json"
    [[ -f "$config_path" ]] || return 0

    python3 - "$config_path" <<'PY'
import json
import sys
from pathlib import Path

try:
    payload = json.loads(Path(sys.argv[1]).read_text())
except Exception:
    raise SystemExit(0)

mac = payload.get("macAddress") or ""
print(mac.strip().lower())
PY
}

lume_standalone_ip_for_mac_from_arp() {
    local target_mac="$1"
    [[ -n "$target_mac" ]] || return 0

    arp -an | python3 -c '
import re
import sys

target = sys.argv[1].lower().replace(":", "")
for line in sys.stdin:
    match = re.search(r"\(([^)]+)\) at ([0-9a-f:]+)", line.lower())
    if not match:
        continue
    ip = match.group(1)
    mac = match.group(2).replace(":", "")
    if mac == target:
        print(ip)
        break
' "$target_mac"
}

lume_standalone_active_subnet_prefix() {
    /sbin/ifconfig en0 2>/dev/null | awk '/inet / { split($2, octets, "."); print octets[1] "." octets[2] "." octets[3]; exit }'
}

lume_standalone_stimulate_arp_on_subnet() {
    local subnet_prefix="$1"
    [[ -n "$subnet_prefix" ]] || return 0

    python3 - "$subnet_prefix" <<'PY'
import concurrent.futures
import socket
import sys

prefix = sys.argv[1]

def probe(octet: int) -> None:
    host = f"{prefix}.{octet}"
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(0.15)
    try:
        sock.connect((host, 22))
    except Exception:
        pass
    finally:
        sock.close()

with concurrent.futures.ThreadPoolExecutor(max_workers=64) as executor:
    list(executor.map(probe, range(1, 255)))
PY
}

lume_standalone_discover_bridged_ip() {
    local vm_name="$1"
    local storage_path="$2"
    local mac_address ip subnet_prefix

    mac_address="$(lume_standalone_vm_mac_address "$vm_name" "$storage_path")"
    [[ -n "$mac_address" ]] || return 1

    ip="$(lume_standalone_ip_for_mac_from_arp "$mac_address")"
    if [[ -n "$ip" ]]; then
        echo "$ip"
        return 0
    fi

    subnet_prefix="$(lume_standalone_active_subnet_prefix)"
    [[ -n "$subnet_prefix" ]] || return 1

    lume_standalone_stimulate_arp_on_subnet "$subnet_prefix" >/dev/null 2>&1 || true
    sleep 1

    ip="$(lume_standalone_ip_for_mac_from_arp "$mac_address")"
    if [[ -n "$ip" ]]; then
        echo "$ip"
        return 0
    fi

    return 1
}

lume_standalone_best_vm_ip() {
    local vm_name="$1"
    local storage_path="$2"
    local snapshot_path="${3:-}"
    local cli_json="${4:-}"
    local daemon_json="${5:-}"
    local ip=""

    if [[ -n "$snapshot_path" && -f "$snapshot_path" ]]; then
        ip="$(lume_standalone_json_field "$snapshot_path" "ipAddress")"
    fi
    if [[ -z "$ip" || "$ip" == "null" ]] && [[ -n "$daemon_json" && -f "$daemon_json" ]]; then
        ip="$(lume_standalone_json_field "$daemon_json" "ipAddress")"
    fi
    if [[ -z "$ip" || "$ip" == "null" ]] && [[ -n "$cli_json" && -f "$cli_json" ]]; then
        ip="$(lume_standalone_json_field "$cli_json" "0.ipAddress")"
    fi
    if [[ -z "$ip" || "$ip" == "null" ]]; then
        ip="$(lume_standalone_discover_bridged_ip "$vm_name" "$storage_path" || true)"
    fi

    if [[ -n "$ip" && "$ip" != "null" ]]; then
        echo "$ip"
        return 0
    fi

    return 1
}

lume_standalone_wait_for_vm_ssh() {
    local vm_name="$1"
    local storage_path="$2"
    local timeout_seconds="$3"
    local daemon_snapshot_path="$4"
    local ssh_probe_path="$5"
    local sentinel="$6"
    local started_at now cli_json daemon_json cli_ok daemon_ok status ip ssh_available sleep_seconds

    started_at="$(date +%s)"
    cli_json="$LUME_STANDALONE_RUN_DIR/.tmp-${vm_name}-cli.json"
    daemon_json="$LUME_STANDALONE_RUN_DIR/.tmp-${vm_name}-daemon.json"

    while true; do
        now="$(date +%s)"
        if (( now - started_at > timeout_seconds )); then
            return 1
        fi

        cli_ok=false
        daemon_ok=false
        if lume_standalone_cli_get_vm "$vm_name" "$storage_path" "$cli_json" >/dev/null 2>&1; then
            cli_ok=true
        fi
        if lume_standalone_daemon_get_vm "$vm_name" "$storage_path" "$daemon_json" >/dev/null 2>&1; then
            daemon_ok=true
            cp "$daemon_json" "$daemon_snapshot_path"
        fi

        if [[ "$cli_ok" == true && "$daemon_ok" == false ]]; then
            export LUME_STANDALONE_STATUS_FAILURE_STAGE="daemon-consistency"
            export LUME_STANDALONE_STATUS_FAILURE_MESSAGE="Lume CLI resolved VM '$vm_name' but the daemon did not."
        fi

        local cli_status daemon_status cli_ip cli_ssh_available daemon_ip daemon_ssh_available
        cli_status=""
        daemon_status=""
        cli_ip=""
        cli_ssh_available=""
        daemon_ip=""
        daemon_ssh_available=""
        [[ "$cli_ok" == true ]] && cli_status="$(lume_standalone_json_field "$cli_json" "0.status")"
        [[ "$daemon_ok" == true ]] && daemon_status="$(lume_standalone_json_field "$daemon_json" "status")"
        [[ "$cli_ok" == true ]] && cli_ip="$(lume_standalone_json_field "$cli_json" "0.ipAddress")"
        [[ "$cli_ok" == true ]] && cli_ssh_available="$(lume_standalone_json_field "$cli_json" "0.sshAvailable")"
        [[ "$daemon_ok" == true ]] && daemon_ip="$(lume_standalone_json_field "$daemon_json" "ipAddress")"
        [[ "$daemon_ok" == true ]] && daemon_ssh_available="$(lume_standalone_json_field "$daemon_json" "sshAvailable")"
        local cli_vnc_url daemon_vnc_url
        cli_vnc_url=""
        daemon_vnc_url=""
        [[ "$cli_ok" == true ]] && cli_vnc_url="$(lume_standalone_json_field "$cli_json" "0.vncUrl")"
        [[ "$daemon_ok" == true ]] && daemon_vnc_url="$(lume_standalone_json_field "$daemon_json" "vncUrl")"

        status="${daemon_status:-$cli_status}"
        ip="${daemon_ip:-}"
        ssh_available="${daemon_ssh_available:-}"

        if [[ -z "$ip" || "$ip" == "null" ]]; then
            ip="${cli_ip:-}"
        fi
        if [[ -z "$ssh_available" || "$ssh_available" == "null" ]]; then
            ssh_available="${cli_ssh_available:-}"
        fi

        if [[ "$status" == "running" ]]; then
            if [[ -z "$ip" || "$ip" == "null" ]]; then
                ip="$(lume_standalone_discover_bridged_ip "$vm_name" "$storage_path" || true)"
            fi
            lume_standalone_write_vm_snapshot \
                "$daemon_snapshot_path" \
                "$vm_name" \
                "$status" \
                "$ip" \
                "$ssh_available" \
                "${daemon_vnc_url:-$cli_vnc_url}"

            if lume_standalone_exec_remote \
                "$vm_name" \
                "$storage_path" \
                "$ip" \
                "printf '$sentinel'" \
                "$ssh_probe_path"
            then
                if grep -q "$sentinel" "$ssh_probe_path"; then
                    return 0
                fi
            fi
        fi

        if [[ "$status" == "running" ]]; then
            sleep_seconds="$LUME_STANDALONE_DEFAULT_RUNNING_SLEEP_SECONDS"
        else
            sleep_seconds="$LUME_STANDALONE_DEFAULT_PREPARING_SLEEP_SECONDS"
        fi
        sleep "$sleep_seconds"
    done
}
