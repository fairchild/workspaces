#!/bin/bash
# ============================================================================
# notarize.sh - Notarize and create DMG for WorkspaceManager
# ============================================================================
#
# This script takes a signed .app bundle (from build-release.sh), creates a
# DMG, submits it for Apple notarization, and staples the ticket.
#
# Usage:
#   ./scripts/notarize.sh              # Build, sign, notarize, create DMG
#   ./scripts/notarize.sh --dmg-only   # Skip notarization (for testing)
#   ./scripts/notarize.sh --help       # Show this help
#
# Prerequisites:
#   1. Run ./scripts/build-release.sh first (or this script will run it)
#   2. Set up scripts/signing-config.sh with your Apple Developer credentials
#   3. Apple Developer Program membership ($99/year)
#
# Output:
#   build/WorkspaceManager-{version}.dmg - Notarized disk image
#
# ============================================================================

set -e  # Exit on error
set -o pipefail  # Exit on pipe failure

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ============================================================================
# Configuration
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="WorkspaceManager"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
SIGNING_CONFIG="${SIGNING_CONFIG:-$SCRIPT_DIR/signing-config.sh}"
CODESIGN_KEYCHAIN_PATH="${CODESIGN_KEYCHAIN_PATH:-}"

# Default bundle ID (can be overridden by signing-config.sh or env)
BUNDLE_ID="${BUNDLE_ID:-com.cloudcompute.workspaces}"

# Flags
DMG_ONLY=false

# ============================================================================
# Parse Arguments
# ============================================================================

for arg in "$@"; do
    case $arg in
        --dmg-only)
            DMG_ONLY=true
            shift
            ;;
        --help|-h)
            head -n 25 "$0" | tail -n +2 | sed 's/^# //' | sed 's/^#//'
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown argument: $arg${NC}"
            exit 1
            ;;
    esac
done

# ============================================================================
# Helper Functions
# ============================================================================

log_step() {
    echo -e "\n${BLUE}==>${NC} $1"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
}

# Get version from Info.plist
get_version() {
    /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || echo "0.0.0"
}

# Get build number from Info.plist
get_build() {
    /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || echo "1"
}

# ============================================================================
# Pre-flight Checks
# ============================================================================

log_step "Pre-flight checks"

# Load signing config when present, otherwise rely on environment variables.
if [[ -f "$SIGNING_CONFIG" ]]; then
    source "$SIGNING_CONFIG"
    log_success "Loaded signing configuration from $SIGNING_CONFIG"
else
    log_warning "signing-config.sh not found - using environment variables"
fi

# Validate required variables
if [[ -z "$TEAM_ID" ]] || [[ "$TEAM_ID" == "XXXXXXXXXX" ]]; then
    log_error "TEAM_ID not configured (set in signing-config.sh or environment)"
    exit 1
fi

if [[ -z "$APPLE_ID" ]] || [[ "$APPLE_ID" == *"example.com" ]]; then
    log_error "APPLE_ID not configured (set in signing-config.sh or environment)"
    exit 1
fi

if [[ -z "$APP_PASSWORD" ]] || [[ "$APP_PASSWORD" == "xxxx-xxxx-xxxx-xxxx" ]]; then
    log_error "APP_PASSWORD not configured (set in signing-config.sh or environment)"
    exit 1
fi

if [[ -z "$SIGNING_IDENTITY" ]] || [[ "$SIGNING_IDENTITY" == *"Your Name"* ]]; then
    log_error "SIGNING_IDENTITY not configured (set in signing-config.sh or environment)"
    exit 1
fi

log_success "Signing configuration validated"

# ============================================================================
# Build App (if needed)
# ============================================================================

if [[ ! -d "$APP_BUNDLE" ]]; then
    log_step "Building app bundle (not found)"
    "$SCRIPT_DIR/build-release.sh"
fi

# Verify app bundle exists and is signed
if [[ ! -d "$APP_BUNDLE" ]]; then
    log_error "App bundle not found at $APP_BUNDLE"
    exit 1
fi
log_success "App bundle found"

# Verify signature
log_step "Verifying existing signature"
if ! codesign --verify --deep --strict "$APP_BUNDLE" 2>/dev/null; then
    log_warning "App is not signed or signature is invalid"
    log_step "Re-building with signing"
    "$SCRIPT_DIR/build-release.sh"
fi
log_success "Signature verified"

# ============================================================================
# Create DMG
# ============================================================================

VERSION=$(get_version)
BUILD_NUM=$(get_build)
DMG_NAME="${APP_NAME}-${VERSION}"
DMG_PATH="$BUILD_DIR/${DMG_NAME}.dmg"

log_step "Creating DMG: $DMG_NAME.dmg"

# Remove existing DMG
rm -f "$DMG_PATH"

# Create a nice DMG with Applications symlink
DMG_TEMP="$BUILD_DIR/dmg_temp"
rm -rf "$DMG_TEMP"
mkdir -p "$DMG_TEMP"

# Copy app to temp directory
cp -R "$APP_BUNDLE" "$DMG_TEMP/"

# Create Applications symlink for easy installation
ln -s /Applications "$DMG_TEMP/Applications"

# Create DMG
hdiutil create \
    -volname "Workspaces $VERSION" \
    -srcfolder "$DMG_TEMP" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    "$DMG_PATH"

# Clean up temp directory
rm -rf "$DMG_TEMP"

log_success "Created DMG: $(du -h "$DMG_PATH" | cut -f1)"

# Sign the DMG
log_step "Signing DMG"
codesign_args=(
    --sign "$SIGNING_IDENTITY"
    --timestamp
    --force
)
if [[ -n "$CODESIGN_KEYCHAIN_PATH" ]]; then
    codesign_args+=(--keychain "$CODESIGN_KEYCHAIN_PATH")
fi
codesign "${codesign_args[@]}" "$DMG_PATH"
log_success "DMG signed"

# ============================================================================
# Notarization
# ============================================================================

if [[ "$DMG_ONLY" == true ]]; then
    log_warning "Skipping notarization (--dmg-only flag)"
else
    log_step "Submitting for notarization"
    echo "  This may take several minutes..."
    echo ""

    # Submit and wait for result
    xcrun notarytool submit "$DMG_PATH" \
        --apple-id "$APPLE_ID" \
        --password "$APP_PASSWORD" \
        --team-id "$TEAM_ID" \
        --wait \
        --progress

    # Check if notarization succeeded
    if [[ $? -ne 0 ]]; then
        log_error "Notarization failed"
        echo ""
        echo "To see detailed logs, run:"
        echo "  xcrun notarytool log <submission-id> --apple-id $APPLE_ID --password <password> --team-id $TEAM_ID"
        exit 1
    fi

    log_success "Notarization complete"

    # Staple the ticket
    log_step "Stapling notarization ticket"
    xcrun stapler staple "$DMG_PATH"
    log_success "Ticket stapled"

    # Verify final result
    log_step "Verifying notarized DMG"
    spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH"
    log_success "DMG verified"
fi

# ============================================================================
# Summary
# ============================================================================

echo ""
echo "============================================================================"
echo -e "${GREEN}Distribution package ready!${NC}"
echo "============================================================================"
echo ""
echo "Version:  $VERSION (build $BUILD_NUM)"
echo "Output:   $DMG_PATH"
echo "Size:     $(du -h "$DMG_PATH" | cut -f1)"
echo ""
echo "Distribution checklist:"
echo "  [ ] Upload to GitHub Releases"
echo "  [ ] Update landing page download link"
echo "  [ ] Test download on a clean Mac"
echo "  [ ] Announce release"
echo ""

# Copy to a version-agnostic name for CI convenience
cp "$DMG_PATH" "$BUILD_DIR/${APP_NAME}-latest.dmg"
echo "Also available as: $BUILD_DIR/${APP_NAME}-latest.dmg"
