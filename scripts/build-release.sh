#!/bin/bash
# ============================================================================
# build-release.sh - Build a release version of WorkspaceManager
# ============================================================================
#
# Creates a signed .app bundle from the Swift Package Manager build.
#
# Usage:
#   ./scripts/build-release.sh           # Build and sign (if config exists)
#   ./scripts/build-release.sh --no-sign # Build without signing
#   ./scripts/build-release.sh --help    # Show this help
#
# Output:
#   build/WorkspaceManager.app - The signed application bundle
#
# Prerequisites for signing:
#   1. Copy scripts/signing-config.sh.template to scripts/signing-config.sh
#   2. Fill in your Apple Developer credentials
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

# Source signing config if it exists
SIGNING_CONFIG="$SCRIPT_DIR/signing-config.sh"
SIGN_APP=true

# ============================================================================
# Parse Arguments
# ============================================================================

for arg in "$@"; do
    case $arg in
        --no-sign)
            SIGN_APP=false
            shift
            ;;
        --help|-h)
            head -n 20 "$0" | tail -n +2 | sed 's/^# //' | sed 's/^#//'
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

# ============================================================================
# Pre-flight Checks
# ============================================================================

log_step "Pre-flight checks"

# Check we're in the right directory
if [[ ! -f "$PROJECT_DIR/Package.swift" ]]; then
    log_error "Package.swift not found. Run from the WorkspaceManager directory."
    exit 1
fi
log_success "Package.swift found"

# Check signing config
if [[ "$SIGN_APP" == true ]]; then
    if [[ -f "$SIGNING_CONFIG" ]]; then
        source "$SIGNING_CONFIG"
        log_success "Loaded signing configuration"
    else
        log_warning "signing-config.sh not found - building without code signing"
        log_warning "Copy signing-config.sh.template and fill in your credentials to enable signing"
        SIGN_APP=false
    fi
fi

# ============================================================================
# Build with Swift Package Manager
# ============================================================================

log_step "Building release binary"

cd "$PROJECT_DIR"

# Clean previous build
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Build release
swift build -c release 2>&1 | while read line; do
    # Show only important lines
    if [[ "$line" == *"error:"* ]] || [[ "$line" == *"warning:"* ]]; then
        echo "$line"
    elif [[ "$line" == *"Build complete"* ]]; then
        echo "$line"
    fi
done

# Check build succeeded
if [[ ! -f ".build/release/$APP_NAME" ]]; then
    log_error "Build failed - executable not found"
    exit 1
fi
log_success "Build complete"

# ============================================================================
# Create App Bundle Structure
# ============================================================================

log_step "Creating app bundle"

# Create bundle directories
# macOS app bundle structure:
#   .app/
#     Contents/
#       Info.plist        <- App metadata
#       MacOS/            <- Executable
#       Resources/        <- Assets, localization, etc.
#       Frameworks/       <- Embedded frameworks (if any)

mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy executable
cp ".build/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"
log_success "Copied executable"

# Copy Info.plist
INFO_PLIST="Sources/WorkspaceManager/Resources/Info.plist"
if [[ -f "$INFO_PLIST" ]]; then
    cp "$INFO_PLIST" "$APP_BUNDLE/Contents/"
    log_success "Copied Info.plist"
else
    log_error "Info.plist not found at $INFO_PLIST"
    exit 1
fi

# Copy Privacy Manifest
PRIVACY_MANIFEST="Sources/WorkspaceManager/Resources/PrivacyInfo.xcprivacy"
if [[ -f "$PRIVACY_MANIFEST" ]]; then
    cp "$PRIVACY_MANIFEST" "$APP_BUNDLE/Contents/Resources/"
    log_success "Copied PrivacyInfo.xcprivacy"
fi

# Copy bundled resources from SPM build (if they exist)
SPM_RESOURCES=".build/release/WorkspaceManager_WorkspaceManager.bundle"
if [[ -d "$SPM_RESOURCES" ]]; then
    cp -R "$SPM_RESOURCES"/* "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || true
    log_success "Copied SPM resources"
fi

# Compile asset catalog (if actool is available and assets exist)
ASSETS_DIR="Sources/WorkspaceManager/Resources/Assets.xcassets"
if [[ -d "$ASSETS_DIR" ]] && command -v actool &> /dev/null; then
    log_step "Compiling asset catalog"

    # actool compiles .xcassets into Assets.car
    actool --compile "$APP_BUNDLE/Contents/Resources" \
           --platform macosx \
           --minimum-deployment-target 14.0 \
           --app-icon AppIcon \
           --output-partial-info-plist "$BUILD_DIR/AssetInfo.plist" \
           "$ASSETS_DIR" 2>/dev/null || log_warning "Asset compilation had warnings"

    if [[ -f "$APP_BUNDLE/Contents/Resources/Assets.car" ]]; then
        log_success "Compiled Assets.car"
    fi
fi

# Create PkgInfo (standard for Mac apps)
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"
log_success "Created PkgInfo"

# ============================================================================
# Code Signing
# ============================================================================

if [[ "$SIGN_APP" == true ]] && [[ -n "$SIGNING_IDENTITY" ]]; then
    log_step "Code signing"

    # Sign embedded frameworks first (if any)
    if [[ -d "$APP_BUNDLE/Contents/Frameworks" ]]; then
        for framework in "$APP_BUNDLE/Contents/Frameworks"/*; do
            codesign --sign "$SIGNING_IDENTITY" \
                     --options runtime \
                     --timestamp \
                     --force \
                     "$framework"
        done
        log_success "Signed embedded frameworks"
    fi

    # Sign the main app bundle with entitlements
    ENTITLEMENTS="$PROJECT_DIR/WorkspaceManager.entitlements"
    if [[ -f "$ENTITLEMENTS" ]]; then
        codesign --sign "$SIGNING_IDENTITY" \
                 --options runtime \
                 --timestamp \
                 --force \
                 --entitlements "$ENTITLEMENTS" \
                 "$APP_BUNDLE"
        log_success "Signed app bundle with entitlements"
    else
        codesign --sign "$SIGNING_IDENTITY" \
                 --options runtime \
                 --timestamp \
                 --force \
                 "$APP_BUNDLE"
        log_success "Signed app bundle"
    fi

    # Verify signature
    log_step "Verifying signature"
    codesign --verify --deep --strict --verbose=1 "$APP_BUNDLE"
    log_success "Signature verified"

    # Check Gatekeeper (informational only - may fail without notarization)
    spctl --assess --type execute --verbose "$APP_BUNDLE" 2>&1 || \
        log_warning "Gatekeeper check failed - app needs notarization for distribution"
else
    log_warning "Skipping code signing"
fi

# ============================================================================
# Summary
# ============================================================================

echo ""
echo "============================================================================"
echo -e "${GREEN}Build complete!${NC}"
echo "============================================================================"
echo ""
echo "Output: $APP_BUNDLE"
echo "Size:   $(du -sh "$APP_BUNDLE" | cut -f1)"
echo ""

if [[ "$SIGN_APP" == true ]] && [[ -n "$SIGNING_IDENTITY" ]]; then
    echo "Next steps for distribution:"
    echo "  1. Run ./scripts/notarize.sh to notarize and create DMG"
    echo ""
else
    echo "Next steps:"
    echo "  1. Set up signing-config.sh for code signing"
    echo "  2. Re-run with signing enabled"
    echo "  3. Run ./scripts/notarize.sh for notarization"
    echo ""
    echo "For local testing, you can run the unsigned app directly:"
    echo "  open $APP_BUNDLE"
fi
