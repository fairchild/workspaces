#!/bin/bash
# ==========================================================================
# lume-host-preflight.sh - Validate this Mac for a real Lume macOS VM smoke
# ==========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LAUNCH_SCRIPT="$REPO_ROOT/scripts/launch-dev.sh"

MIN_LUME_FREE_GB="${LUME_HOST_SMOKE_MIN_LUME_FREE_GB:-80}"
MIN_WORKSPACE_FREE_GB="${LUME_HOST_SMOKE_MIN_WORKSPACE_FREE_GB:-20}"
SKIP_BUILD=false
NO_ACTIVATE=false
DATA_DIR="$REPO_ROOT/.dev-data/lume-preflight"
LUME_STORAGE_ROOT="${LUME_STORAGE_ROOT:-$HOME/Library/Application Support/WorkspaceManager/LumeStorage}"

log() {
    echo "[$(date +%H:%M:%S)] $*"
}

warn() {
    echo "[$(date +%H:%M:%S)] WARNING: $*" >&2
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
Usage: ./scripts/lume-host-preflight.sh [options]

Options:
  --no-build      Reuse the current debug binary
  --no-activate   Keep launch verification in shared-desktop mode
  --help, -h      Show this help
USAGE
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-build)
                SKIP_BUILD=true
                shift
                ;;
            --no-activate)
                NO_ACTIVATE=true
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                fail "Unknown argument: $1"
                ;;
        esac
    done
}

available_gigabytes() {
    local target_path="$1"
    df -g "$target_path" | awk 'NR==2 { print $4 }'
}

assert_free_space() {
    local target_path="$1"
    local minimum_gb="$2"
    local label="$3"
    local available_gb
    available_gb="$(available_gigabytes "$target_path")"

    [[ -n "$available_gb" ]] || fail "Could not determine free space for $label ($target_path)"

    if (( available_gb < minimum_gb )); then
        fail "$label needs at least ${minimum_gb}GB free, but only ${available_gb}GB is available at $target_path"
    fi

    log "$label free space: ${available_gb}GB"
}

report_host_profile() {
    local macos_version xcode_version developer_dir
    macos_version="$(/usr/bin/sw_vers -productVersion)"
    xcode_version="$( (/usr/bin/xcodebuild -version 2>/dev/null || true) | awk '/^Xcode / { print $2 }' )"
    developer_dir="$( (/usr/bin/xcode-select -p 2>/dev/null || true) | head -n 1 )"

    log "Host macOS: $macos_version"
    if [[ -n "$xcode_version" ]]; then
        log "Host Xcode: $xcode_version"
    else
        log "Host Xcode: not detected"
    fi
    if [[ -n "$developer_dir" ]]; then
        log "Developer directory: $developer_dir"
    fi
}

check_restore_image_discovery() {
    log "Checking host macOS restore-image discovery..."

    local direct_output
    if direct_output="$(swift - <<'SWIFT'
import Foundation
import Virtualization

let semaphore = DispatchSemaphore(value: 0)
var exitCode: Int32 = 1

if #available(macOS 12.0, *) {
    VZMacOSRestoreImage.fetchLatestSupported { result in
        switch result {
        case .success(let image):
            let buildVersion = image.operatingSystemVersion
            print("restore_image=\(buildVersion.majorVersion).\(buildVersion.minorVersion).\(buildVersion.patchVersion)")
            exitCode = 0
        case .failure(let error):
            fputs("restore_image_error=\(error.localizedDescription)\n", stderr)
            exitCode = 1
        }
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 120)
    Foundation.exit(exitCode)
} else {
    fputs("restore_image_error=Virtualization framework is unavailable on this macOS version.\n", stderr)
    Foundation.exit(1)
}
SWIFT
    2>&1)"; then
        printf '%s\n' "$direct_output"
        return
    fi

    warn "Direct Virtualization restore-image discovery failed: $direct_output"

    local lume_bin="$HOME/.local/bin/lume"
    if [[ -x "$lume_bin" ]]; then
        log "Falling back to host-side 'lume ipsw' validation..."
        local lume_output
        if lume_output="$("$lume_bin" ipsw 2>&1)"; then
            printf '%s\n' "$lume_output"
            warn "Continuing because host-side 'lume ipsw' succeeded even though the raw Virtualization probe failed."
            return
        fi

        fail "Both direct restore-image discovery and 'lume ipsw' failed. Stock macOS fallback provisioning is not healthy."
    fi

    warn "Lume is not installed yet, so no CLI fallback check is available. The first-use setup flow may still succeed."
}

launch_debug_app_check() {
    log "Verifying debug app build and launch..."
    local -a args=("--data-dir" "$DATA_DIR" "--clean-data" "--window-timeout" "15")
    if [[ "$SKIP_BUILD" == true ]]; then
        args+=("--no-build")
    fi
    if [[ "$NO_ACTIVATE" == true ]]; then
        args+=("--no-activate")
    fi

    (
        cd "$REPO_ROOT"
        "$LAUNCH_SCRIPT" "${args[@]}"
    )

    pkill -f "$REPO_ROOT/.build/arm64-apple-macosx/debug/WorkspaceManager" >/dev/null 2>&1 || true
    sleep 1
}

report_optional_lume_status() {
    local lume_bin="$HOME/.local/bin/lume"
    if [[ ! -x "$lume_bin" ]]; then
        log "Lume status: not installed yet (first-use setup path will install it)"
        return
    fi

    log "Lume executable: $lume_bin"
    "$lume_bin" --version || true

    if curl -fsS "http://localhost:7777/lume/host/status" >/dev/null 2>&1; then
        log "Lume daemon: reachable on localhost:7777"
    else
        log "Lume daemon: not reachable on localhost:7777"
    fi
}

main() {
    parse_args "$@"

    [[ "$(uname -m)" == "arm64" ]] || fail "Real Lume macOS VM smoke requires Apple Silicon."

    mkdir -p "$LUME_STORAGE_ROOT" "$HOME/workspaces"

    assert_free_space "$LUME_STORAGE_ROOT" "$MIN_LUME_FREE_GB" "Lume storage"
    assert_free_space "$HOME/workspaces" "$MIN_WORKSPACE_FREE_GB" "Workspace storage"
    report_host_profile
    check_restore_image_discovery
    report_optional_lume_status
    launch_debug_app_check

    log "Lume host preflight passed."
}

main "$@"
