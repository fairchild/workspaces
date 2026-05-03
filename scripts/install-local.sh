#!/bin/bash
# ==========================================================================
# install-local.sh - Build and replace local /Applications install
# ==========================================================================
#
# Common local testing workflow:
#   1) Build WorkspaceManager.app
#   2) Replace the local installed app bundle
#   3) Optionally relaunch the app
#
# Default behavior prefers a signed/provisioned packaged app when local signing
# material is configured. Otherwise it falls back to an unsigned build, which
# uses the runtime legacy-keychain fallback instead of the data protection
# keychain.
#
# Usage:
#   ./scripts/install-local.sh                         # Prefer signed when configured
#   ./scripts/install-local.sh --signed               # Require signed/provisioned build
#   ./scripts/install-local.sh --unsigned             # Force unsigned/ad-hoc build
#   ./scripts/install-local.sh --no-build             # Install existing build/ app
#   ./scripts/install-local.sh --no-open              # Do not relaunch app
#   ./scripts/install-local.sh --dest <path>          # Install to custom .app path
#
# ==========================================================================

set -e
set -o pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="WorkspaceManager"
CLI_NAME="workspaces"
CLI_HELPER_RELATIVE_PATH="Contents/Helpers/$CLI_NAME"
CLI_LEGACY_RELATIVE_PATH="Contents/MacOS/$CLI_NAME"
SOURCE_APP="$PROJECT_DIR/build/$APP_NAME.app"
DEST_APP="/Applications/$APP_NAME.app"
SIGNING_CONFIG="${SIGNING_CONFIG:-$SCRIPT_DIR/signing-config.sh}"
VERIFY_KEYCHAIN_SIGNING_SCRIPT="$SCRIPT_DIR/verify-app-keychain-signing.sh"

BUILD_MODE="auto"
SKIP_BUILD=false
OPEN_AFTER_INSTALL=true
LINK_CLI=true
CLI_LINK_PATH=""

EFFECTIVE_SIGNING_IDENTITY=""
EFFECTIVE_PROVISIONING_PROFILE_PATH=""

usage() {
    cat <<'USAGE'
Usage: ./scripts/install-local.sh [options]

Options:
  --signed        Require a signed/provisioned packaged build
  --unsigned      Force an unsigned/ad-hoc packaged build
  --no-build      Skip build and install existing build/WorkspaceManager.app
  --no-open       Do not relaunch app after install
  --no-cli-link   Do not update the `workspaces` CLI symlink
  --cli-link <path>
                  Override CLI symlink path (default: first writable PATH dir)
  --dest <path>   Install destination app bundle path
  --help, -h      Show this help

Defaults:
  Without --signed/--unsigned, the script prefers a signed/provisioned build
  when SIGNING_IDENTITY and PROVISIONING_PROFILE_PATH are configured.
USAGE
}

log_step() {
    echo -e "\n${BLUE}==>${NC} $1"
}

log_success() {
    echo -e "${GREEN}OK${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}WARN${NC} $1"
}

log_error() {
    echo -e "${RED}ERR${NC} $1"
}

fail() {
    log_error "$1"
    exit 1
}

expand_home_prefix() {
    local path="$1"
    if [[ "$path" == "~" ]]; then
        printf '%s\n' "$HOME"
        return
    fi
    if [[ "$path" == "~/"* ]]; then
        printf '%s\n' "$HOME/${path#~/}"
        return
    fi
    printf '%s\n' "$path"
}

resolve_default_cli_link_path() {
    local dir=""
    for dir in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/bin"; do
        local parent=""
        parent="$(dirname "$dir")"
        if [[ -d "$dir" && -w "$dir" ]]; then
            printf '%s/%s\n' "$dir" "$CLI_NAME"
            return 0
        fi
        if [[ ! -d "$dir" && -d "$parent" && -w "$parent" ]]; then
            printf '%s/%s\n' "$dir" "$CLI_NAME"
            return 0
        fi
    done

    local original_ifs="$IFS"
    IFS=':'
    for dir in $PATH; do
        [[ -n "$dir" ]] || continue
        if [[ -d "$dir" && -w "$dir" ]]; then
            printf '%s/%s\n' "$dir" "$CLI_NAME"
            IFS="$original_ifs"
            return 0
        fi
    done
    IFS="$original_ifs"

    return 1
}

load_signing_context() {
    if [[ -f "$SIGNING_CONFIG" ]]; then
        # shellcheck disable=SC1090
        source "$SIGNING_CONFIG"
    fi

    EFFECTIVE_SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
    EFFECTIVE_PROVISIONING_PROFILE_PATH="${PROVISIONING_PROFILE_PATH:-}"
    if [[ -n "$EFFECTIVE_PROVISIONING_PROFILE_PATH" ]]; then
        EFFECTIVE_PROVISIONING_PROFILE_PATH="$(expand_home_prefix "$EFFECTIVE_PROVISIONING_PROFILE_PATH")"
    fi
}

can_build_signed() {
    [[ -n "$EFFECTIVE_SIGNING_IDENTITY" ]] || return 1
    [[ -n "$EFFECTIVE_PROVISIONING_PROFILE_PATH" ]] || return 1
    [[ -f "$EFFECTIVE_PROVISIONING_PROFILE_PATH" ]] || return 1
}

resolve_build_mode() {
    load_signing_context

    case "$BUILD_MODE" in
        signed)
            can_build_signed || fail "Signed install requires SIGNING_IDENTITY and a valid PROVISIONING_PROFILE_PATH"
            ;;
        auto)
            if can_build_signed; then
                BUILD_MODE="signed"
            else
                BUILD_MODE="unsigned"
                log_warning "Signed packaged build is not configured; proceeding with unsigned install"
                log_warning "Unsigned / ad-hoc installs use the runtime legacy-keychain fallback"
            fi
            ;;
        unsigned)
            ;;
        *)
            fail "Unsupported build mode: $BUILD_MODE"
            ;;
    esac
}

report_keychain_mode() {
    local app_bundle="$1"
    local output=""

    if output="$("$VERIFY_KEYCHAIN_SIGNING_SCRIPT" "$app_bundle" 2>&1)"; then
        log_success "$output"
        return
    fi

    if [[ "$BUILD_MODE" == "signed" ]]; then
        fail "Signed install verification failed: $output"
    fi

    log_warning "Installed app will use the runtime legacy-keychain fallback"
    log_warning "$output"
}

resolve_cli_source() {
    local app_path="$1"

    local helper_path="$app_path/$CLI_HELPER_RELATIVE_PATH"
    if [[ -x "$helper_path" ]]; then
        printf '%s\n' "$helper_path"
        return 0
    fi

    local legacy_path="$app_path/$CLI_LEGACY_RELATIVE_PATH"
    if [[ -x "$legacy_path" ]]; then
        printf '%s\n' "$legacy_path"
        return 0
    fi

    return 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --signed)
            BUILD_MODE="signed"
            shift
            ;;
        --unsigned)
            BUILD_MODE="unsigned"
            shift
            ;;
        --no-build)
            SKIP_BUILD=true
            shift
            ;;
        --no-open)
            OPEN_AFTER_INSTALL=false
            shift
            ;;
        --no-cli-link)
            LINK_CLI=false
            shift
            ;;
        --cli-link)
            [[ $# -ge 2 ]] || fail "--cli-link requires a value"
            CLI_LINK_PATH="$2"
            shift 2
            ;;
        --dest)
            [[ $# -ge 2 ]] || fail "--dest requires a value"
            DEST_APP="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            usage
            fail "Unknown argument: $1"
            ;;
    esac
done

[[ -f "$PROJECT_DIR/Package.swift" ]] || fail "Package.swift not found. Run from repo root or scripts/ directory."
[[ "$DEST_APP" == *.app ]] || fail "Destination must be a .app bundle path: $DEST_APP"
[[ -x "$VERIFY_KEYCHAIN_SIGNING_SCRIPT" ]] || fail "Missing verifier script at $VERIFY_KEYCHAIN_SIGNING_SCRIPT"

resolve_build_mode

if [[ "$SKIP_BUILD" == false ]]; then
    log_step "Building app bundle"
    cd "$PROJECT_DIR"

    case "$BUILD_MODE" in
        signed)
            "$SCRIPT_DIR/build-release.sh"
            ;;
        unsigned)
            if [[ -n "$EFFECTIVE_SIGNING_IDENTITY" ]] || [[ -n "$EFFECTIVE_PROVISIONING_PROFILE_PATH" ]]; then
                log_warning "Signing configuration is incomplete or unsigned mode was requested; building unsigned app"
            fi
            "$SCRIPT_DIR/build-release.sh" --no-sign
            ;;
    esac
else
    log_step "Skipping build (--no-build)"
fi

[[ -d "$SOURCE_APP" ]] || fail "Source app not found: $SOURCE_APP"

log_step "Stopping running app (if open)"
osascript -e 'tell application id "com.cloudcompute.workspaces" to quit' >/dev/null 2>&1 || true
osascript -e 'tell application "WorkspaceManager" to quit' >/dev/null 2>&1 || true
osascript -e 'tell application "WorkSpaces" to quit' >/dev/null 2>&1 || true
osascript -e 'tell application "Workspaces" to quit' >/dev/null 2>&1 || true
pkill -x WorkspaceManager >/dev/null 2>&1 || true
sleep 1

log_step "Installing app bundle"
DEST_PARENT="$(dirname "$DEST_APP")"
if [[ ! -d "$DEST_PARENT" ]]; then
    mkdir -p "$DEST_PARENT"
fi

TMP_DEST="${DEST_APP}.tmp.$$"
rm -rf "$TMP_DEST"

if ! ditto "$SOURCE_APP" "$TMP_DEST"; then
    rm -rf "$TMP_DEST"
    fail "Failed to copy app bundle to temporary destination"
fi

rm -rf "$DEST_APP"
mv "$TMP_DEST" "$DEST_APP"
log_success "Installed: $DEST_APP"

SOURCE_BIN="$SOURCE_APP/Contents/MacOS/$APP_NAME"
DEST_BIN="$DEST_APP/Contents/MacOS/$APP_NAME"
if [[ -f "$SOURCE_BIN" && -f "$DEST_BIN" ]]; then
    SOURCE_SHA="$(shasum -a 256 "$SOURCE_BIN" | awk '{print $1}')"
    DEST_SHA="$(shasum -a 256 "$DEST_BIN" | awk '{print $1}')"
    if [[ "$SOURCE_SHA" == "$DEST_SHA" ]]; then
        log_success "Binary verified (SHA-256 match)"
    else
        log_warning "Binary checksum mismatch; verify install manually"
    fi
fi

report_keychain_mode "$DEST_APP"

if [[ "$OPEN_AFTER_INSTALL" == true ]]; then
    log_step "Launching installed app"
    open "$DEST_APP"
fi

if [[ "$LINK_CLI" == true ]]; then
    if CLI_SOURCE="$(resolve_cli_source "$DEST_APP")"; then
        if [[ -z "$CLI_LINK_PATH" ]]; then
            if ! CLI_LINK_PATH="$(resolve_default_cli_link_path)"; then
                log_warning "No writable PATH directory found for CLI link; use $CLI_SOURCE directly"
                CLI_LINK_PATH=""
            fi
        fi

        if [[ -n "$CLI_LINK_PATH" ]]; then
            CLI_LINK_PATH="$(expand_home_prefix "$CLI_LINK_PATH")"
            CLI_LINK_DIR="$(dirname "$CLI_LINK_PATH")"
            mkdir -p "$CLI_LINK_DIR"
            CLI_LINK_DIR="$(cd "$CLI_LINK_DIR" && pwd)"
            CLI_LINK_PATH="$CLI_LINK_DIR/$(basename "$CLI_LINK_PATH")"

            if [[ -e "$CLI_LINK_PATH" && ! -L "$CLI_LINK_PATH" ]]; then
                log_warning "Skipping CLI link because a non-symlink file exists at $CLI_LINK_PATH"
            else
                ln -sfn "$CLI_SOURCE" "$CLI_LINK_PATH"
                log_success "Linked CLI: $CLI_LINK_PATH"
            fi
        fi
    else
        log_warning "CLI launcher not found in app bundle; skipping CLI link"
    fi
fi
