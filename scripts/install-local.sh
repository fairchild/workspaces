#!/bin/bash
# ==========================================================================
# install-local.sh - Build and replace local /Applications install
# ==========================================================================
#
# Common local testing workflow:
#   1) Build WorkspaceManager.app
#   2) Replace /Applications/WorkspaceManager.app
#   3) Optionally relaunch the app
#
# Usage:
#   ./scripts/install-local.sh                 # Unsiged build + install + open
#   ./scripts/install-local.sh --signed        # Signed build + install + open
#   ./scripts/install-local.sh --no-build      # Install existing build/ app
#   ./scripts/install-local.sh --no-open       # Do not relaunch after install
#   ./scripts/install-local.sh --dest <path>   # Install to custom .app path
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
SOURCE_APP="$PROJECT_DIR/build/$APP_NAME.app"
DEST_APP="/Applications/$APP_NAME.app"

BUILD_SIGNED=false
SKIP_BUILD=false
OPEN_AFTER_INSTALL=true
LINK_CLI=true
CLI_LINK_PATH=""

usage() {
    cat <<USAGE
Usage: ./scripts/install-local.sh [options]

Options:
  --signed        Build with signing (uses scripts/build-release.sh)
  --no-build      Skip build and install existing build/WorkspaceManager.app
  --no-open       Do not relaunch app after install
  --no-cli-link   Do not update the `workspaces` CLI symlink
  --cli-link <path>
                  Override CLI symlink path (default: first writable PATH dir)
  --dest <path>   Install destination app bundle path
  --help, -h      Show this help
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

resolve_default_cli_link_path() {
    local dir
    # Keep this preference order in sync with
    # Sources/WorkspaceManager/Services/CommandLineToolService.swift.
    for dir in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/bin"; do
        local parent
        parent="$(dirname "$dir")"
        if [[ -d "$dir" && -w "$dir" ]]; then
            printf "%s/%s\n" "$dir" "$CLI_NAME"
            return 0
        fi
        if [[ ! -d "$dir" && -d "$parent" && -w "$parent" ]]; then
            printf "%s/%s\n" "$dir" "$CLI_NAME"
            return 0
        fi
    done

    local original_ifs="$IFS"
    IFS=':'
    for dir in $PATH; do
        [[ -n "$dir" ]] || continue
        if [[ -d "$dir" && -w "$dir" ]]; then
            printf "%s/%s\n" "$dir" "$CLI_NAME"
            IFS="$original_ifs"
            return 0
        fi
    done
    IFS="$original_ifs"

    return 1
}

expand_home_prefix() {
    local path="$1"
    if [[ "$path" == "~" ]]; then
        printf "%s\n" "$HOME"
        return
    fi
    if [[ "$path" == "~/"* ]]; then
        printf "%s\n" "$HOME/${path#~/}"
        return
    fi
    printf "%s\n" "$path"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --signed)
            BUILD_SIGNED=true
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
            if [[ $# -lt 2 ]]; then
                log_error "--cli-link requires a value"
                exit 1
            fi
            CLI_LINK_PATH="$2"
            shift 2
            ;;
        --dest)
            if [[ $# -lt 2 ]]; then
                log_error "--dest requires a value"
                exit 1
            fi
            DEST_APP="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ ! -f "$PROJECT_DIR/Package.swift" ]]; then
    log_error "Package.swift not found. Run from repo root or scripts/ directory."
    exit 1
fi

if [[ ! "$DEST_APP" == *.app ]]; then
    log_error "Destination must be a .app bundle path: $DEST_APP"
    exit 1
fi

if [[ "$SKIP_BUILD" == false ]]; then
    log_step "Building app bundle"
    cd "$PROJECT_DIR"
    if [[ "$BUILD_SIGNED" == true ]]; then
        "$SCRIPT_DIR/build-release.sh"
    else
        "$SCRIPT_DIR/build-release.sh" --no-sign
    fi
else
    log_step "Skipping build (--no-build)"
fi

if [[ ! -d "$SOURCE_APP" ]]; then
    log_error "Source app not found: $SOURCE_APP"
    exit 1
fi

log_step "Stopping running app (if open)"
osascript -e 'tell application id "com.cloudcompute.workspaces" to quit' >/dev/null 2>&1 || true
osascript -e 'tell application "WorkspaceManager" to quit' >/dev/null 2>&1 || true
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
    log_error "Failed to copy app bundle to temporary destination"
    rm -rf "$TMP_DEST"
    exit 1
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

if [[ "$OPEN_AFTER_INSTALL" == true ]]; then
    log_step "Launching installed app"
    open "$DEST_APP"
fi

if [[ "$LINK_CLI" == true ]]; then
    CLI_SOURCE="$DEST_APP/Contents/MacOS/$CLI_NAME"
    if [[ -x "$CLI_SOURCE" ]]; then
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

echo ""
echo "Installed app: $DEST_APP"
echo "Source app:    $SOURCE_APP"
