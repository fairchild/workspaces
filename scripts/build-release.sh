#!/bin/bash
# ============================================================================
# build-release.sh - Build a release version of WorkSpaces
# ============================================================================
#
# Creates a packaged .app bundle from the Swift Package Manager build.
#
# Usage:
#   ./scripts/build-release.sh           # Build and sign (requires provisioning profile)
#   ./scripts/build-release.sh --no-sign # Build without signing
#   ./scripts/build-release.sh --help    # Show this help
#
# Output:
#   build/WorkSpaces.app - The packaged application bundle
#
# Signed builds require:
#   1. Copy scripts/signing-config.sh.template to scripts/signing-config.sh
#   2. Fill in signing identity and PROVISIONING_PROFILE_PATH
#
# Unsigned / ad-hoc builds remain supported for local development but will use
# the runtime legacy-keychain fallback instead of the data protection keychain.
#
# ============================================================================

set -e
set -o pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
APP_BUNDLE_NAME="WorkSpaces"
EXECUTABLE_NAME="WorkspaceManager"
CLI_NAME="workspaces"
APP_BUNDLE="$BUILD_DIR/$APP_BUNDLE_NAME.app"
VERIFY_KEYCHAIN_SIGNING_SCRIPT="$SCRIPT_DIR/verify-app-keychain-signing.sh"
VERIFY_RELEASE_BUNDLE_SCRIPT="$SCRIPT_DIR/verify-release-bundle.sh"
PLIST_BUDDY="/usr/libexec/PlistBuddy"
CLI_BUNDLE_RELATIVE_PATH="Contents/Helpers/$CLI_NAME"

SIGNING_CONFIG="${SIGNING_CONFIG:-$SCRIPT_DIR/signing-config.sh}"
CODESIGN_KEYCHAIN_PATH="${CODESIGN_KEYCHAIN_PATH:-}"
PROVISIONING_PROFILE_PATH="${PROVISIONING_PROFILE_PATH:-}"
BUNDLE_ID="${BUNDLE_ID:-com.cloudcompute.workspaces}"
SIGN_APP=true

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/workspaces-build-release.XXXXXX")"
PROFILE_PLIST="$TMP_DIR/provisioning-profile.plist"
SIGNING_ENTITLEMENTS_PLIST="$TMP_DIR/WorkspaceManager-signing.entitlements"

PROFILE_APPLICATION_IDENTIFIER=""
PROFILE_TEAM_ID=""
PROFILE_PLATFORM=""
EXPECTED_APPLICATION_IDENTIFIER=""
EXPECTED_KEYCHAIN_GROUP=""

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

usage() {
    cat <<'EOF'
build-release.sh - Build a release version of WorkSpaces

Usage:
  ./scripts/build-release.sh           Build and sign with provisioning profile
  ./scripts/build-release.sh --no-sign Build without signing
  ./scripts/build-release.sh --help    Show this help

Signed builds require SIGNING_IDENTITY and PROVISIONING_PROFILE_PATH.
Unsigned builds are suitable for local development but use the runtime legacy
keychain fallback instead of the data protection keychain.
EOF
}

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

fail() {
    log_error "$1"
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
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

resolve_ghostty_share_dir() {
    local -a candidates=()
    local candidate=""

    if [[ -n "${GHOSTTY_SHARE_DIR:-}" ]]; then
        candidates+=("$(expand_home_prefix "$GHOSTTY_SHARE_DIR")")
    fi

    if [[ -n "${GHOSTTY_DIR:-}" ]]; then
        candidates+=("$(expand_home_prefix "$GHOSTTY_DIR")/zig-out/share")
    fi

    candidates+=("$HOME/.cache/workspacemanager/ghostty/zig-out/share")

    for candidate in "${candidates[@]}"; do
        if [[ -d "$candidate/ghostty" ]] && [[ -d "$candidate/terminfo" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

plist_print() {
    local plist_path="$1"
    local key_path="$2"
    "$PLIST_BUDDY" -c "Print :$key_path" "$plist_path" 2>/dev/null || true
}

plist_array_values() {
    local plist_path="$1"
    local key_path="$2"
    local index=0
    local value=""

    while value="$("$PLIST_BUDDY" -c "Print :$key_path:$index" "$plist_path" 2>/dev/null)"; do
        printf '%s\n' "$value"
        index=$((index + 1))
    done
}

pattern_matches_value() {
    local value="$1"
    local pattern="$2"

    if [[ "$pattern" == *"*" ]]; then
        local prefix="${pattern%\*}"
        [[ "$value" == "$prefix"* ]]
        return
    fi

    [[ "$value" == "$pattern" ]]
}

array_authorizes_value() {
    local expected="$1"
    shift

    local item=""
    for item in "$@"; do
        if pattern_matches_value "$expected" "$item"; then
            return 0
        fi
    done

    return 1
}

plist_set_string() {
    local plist_path="$1"
    local key_path="$2"
    local value="$3"

    "$PLIST_BUDDY" -c "Delete :$key_path" "$plist_path" >/dev/null 2>&1 || true
    "$PLIST_BUDDY" -c "Add :$key_path string $value" "$plist_path"
}

plist_replace_single_string_array() {
    local plist_path="$1"
    local key_path="$2"
    local value="$3"

    "$PLIST_BUDDY" -c "Delete :$key_path" "$plist_path" >/dev/null 2>&1 || true
    "$PLIST_BUDDY" -c "Add :$key_path array" "$plist_path"
    "$PLIST_BUDDY" -c "Add :$key_path:0 string $value" "$plist_path"
}

merge_icon_metadata() {
    local asset_info_plist="$1"
    local app_info_plist="$2"

    if [[ ! -f "$asset_info_plist" ]] || [[ ! -f "$app_info_plist" ]]; then
        return
    fi

    local icon_file=""
    local icon_name=""
    icon_file="$(plist_print "$asset_info_plist" "CFBundleIconFile")"
    icon_name="$(plist_print "$asset_info_plist" "CFBundleIconName")"

    if [[ -n "$icon_file" ]]; then
        plutil -replace CFBundleIconFile -string "$icon_file" "$app_info_plist"
    fi

    if [[ -n "$icon_name" ]]; then
        plutil -replace CFBundleIconName -string "$icon_name" "$app_info_plist"
    fi

    if [[ -n "$icon_file" ]] || [[ -n "$icon_name" ]]; then
        log_success "Merged icon metadata into Info.plist"
    fi
}

codesign_with_identity() {
    local target="$1"
    shift

    # SwiftPM ad-hoc signs binaries at build time. Replacing that signature
    # has surfaced errSecInternalComponent on self-hosted runners where
    # securityd's access path is fragile; stripping first avoids the replace
    # codepath entirely.
    codesign --remove-signature "$target" 2>/dev/null || true

    local -a cmd=(
        codesign
        --sign "$SIGNING_IDENTITY"
        --options runtime
        --timestamp
        --force
    )

    if [[ -n "$CODESIGN_KEYCHAIN_PATH" ]]; then
        cmd+=(--keychain "$CODESIGN_KEYCHAIN_PATH")
    fi

    if (( $# > 0 )); then
        cmd+=("$@")
    fi

    cmd+=("$target")

    local attempt rc=0
    for attempt in 1 2 3; do
        if "${cmd[@]}"; then
            return 0
        fi
        rc=$?
        if (( attempt < 3 )); then
            log_warning "codesign failed for $target (attempt $attempt/3), retrying in 2s..."
            sleep 2
        fi
    done
    return "$rc"
}

prepare_signing_assets() {
    require_cmd security
    [[ -x "$PLIST_BUDDY" ]] || fail "PlistBuddy not found at $PLIST_BUDDY"
    [[ -x "$VERIFY_KEYCHAIN_SIGNING_SCRIPT" ]] || fail "Missing verifier script at $VERIFY_KEYCHAIN_SIGNING_SCRIPT"
    [[ -x "$VERIFY_RELEASE_BUNDLE_SCRIPT" ]] || fail "Missing verifier script at $VERIFY_RELEASE_BUNDLE_SCRIPT"
    [[ -n "${SIGNING_IDENTITY:-}" ]] || fail "SIGNING_IDENTITY must be set for signed builds"
    [[ -n "$PROVISIONING_PROFILE_PATH" ]] || fail "PROVISIONING_PROFILE_PATH is required for signed builds"

    PROVISIONING_PROFILE_PATH="$(expand_home_prefix "$PROVISIONING_PROFILE_PATH")"
    [[ -f "$PROVISIONING_PROFILE_PATH" ]] || fail "Provisioning profile not found: $PROVISIONING_PROFILE_PATH"

    if ! security cms -D -i "$PROVISIONING_PROFILE_PATH" >"$PROFILE_PLIST"; then
        fail "Failed to decode provisioning profile: $PROVISIONING_PROFILE_PATH"
    fi

    PROFILE_PLATFORM="$(plist_print "$PROFILE_PLIST" "Platform:0")"
    [[ "$PROFILE_PLATFORM" == "OSX" ]] || fail "Provisioning profile platform must be OSX for macOS packaged builds (got ${PROFILE_PLATFORM:-<missing>})"

    PROFILE_APPLICATION_IDENTIFIER="$(plist_print "$PROFILE_PLIST" "Entitlements:application-identifier")"
    if [[ -z "$PROFILE_APPLICATION_IDENTIFIER" ]]; then
        PROFILE_APPLICATION_IDENTIFIER="$(plist_print "$PROFILE_PLIST" "Entitlements:com.apple.application-identifier")"
    fi
    [[ -n "$PROFILE_APPLICATION_IDENTIFIER" ]] || fail "Provisioning profile is missing application-identifier entitlement"

    PROFILE_TEAM_ID="$(plist_print "$PROFILE_PLIST" "Entitlements:com.apple.developer.team-identifier")"
    if [[ -z "$PROFILE_TEAM_ID" ]]; then
        PROFILE_TEAM_ID="$(plist_print "$PROFILE_PLIST" "TeamIdentifier:0")"
    fi
    [[ -n "$PROFILE_TEAM_ID" ]] || fail "Provisioning profile is missing a team identifier"

    local app_id_prefix="${PROFILE_APPLICATION_IDENTIFIER%%.*}"
    [[ "$app_id_prefix" != "$PROFILE_APPLICATION_IDENTIFIER" ]] || fail "Provisioning profile application-identifier is malformed: $PROFILE_APPLICATION_IDENTIFIER"

    EXPECTED_APPLICATION_IDENTIFIER="$app_id_prefix.$BUNDLE_ID"
    EXPECTED_KEYCHAIN_GROUP="$app_id_prefix.$BUNDLE_ID"

    pattern_matches_value "$EXPECTED_APPLICATION_IDENTIFIER" "$PROFILE_APPLICATION_IDENTIFIER" \
        || fail "Provisioning profile does not authorize bundle identifier $BUNDLE_ID"

    local -a profile_keychain_groups=()
    local keychain_group=""
    while IFS= read -r keychain_group; do
        profile_keychain_groups+=("$keychain_group")
    done < <(plist_array_values "$PROFILE_PLIST" "Entitlements:keychain-access-groups")
    (( ${#profile_keychain_groups[@]} > 0 )) || fail "Provisioning profile is missing keychain-access-groups"

    array_authorizes_value "$EXPECTED_KEYCHAIN_GROUP" "${profile_keychain_groups[@]}" \
        || fail "Provisioning profile does not authorize keychain group $EXPECTED_KEYCHAIN_GROUP"

    if [[ -n "${TEAM_ID:-}" ]] && [[ "$TEAM_ID" != "XXXXXXXXXX" ]] && [[ "$TEAM_ID" != "$PROFILE_TEAM_ID" ]]; then
        fail "TEAM_ID ($TEAM_ID) does not match provisioning profile team identifier ($PROFILE_TEAM_ID)"
    fi

    local base_entitlements="$PROJECT_DIR/WorkspaceManager.entitlements"
    [[ -f "$base_entitlements" ]] || fail "Base entitlements file not found: $base_entitlements"

    cp "$base_entitlements" "$SIGNING_ENTITLEMENTS_PLIST"
    plist_set_string "$SIGNING_ENTITLEMENTS_PLIST" "com.apple.application-identifier" "$EXPECTED_APPLICATION_IDENTIFIER"
    plist_set_string "$SIGNING_ENTITLEMENTS_PLIST" "com.apple.developer.team-identifier" "$PROFILE_TEAM_ID"
    plist_replace_single_string_array "$SIGNING_ENTITLEMENTS_PLIST" "keychain-access-groups" "$EXPECTED_KEYCHAIN_GROUP"

    log_success "Prepared signing entitlements for $EXPECTED_KEYCHAIN_GROUP"
}

verify_signed_keychain_access() {
    log_step "Verifying keychain signing"
    local output=""
    output="$("$VERIFY_KEYCHAIN_SIGNING_SCRIPT" "$APP_BUNDLE" 2>&1)" || fail "$output"
    log_success "$output"
}

verify_release_bundle_signing() {
    log_step "Verifying release bundle signing"
    local output=""
    output="$("$VERIFY_RELEASE_BUNDLE_SCRIPT" "$APP_BUNDLE" 2>&1)" || fail "$output"
    log_success "$output"
}

verify_sparkle_bundle_linkage() {
    local executable="$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
    local framework_binary="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"

    log_step "Verifying Sparkle bundle linkage"

    [[ -x "$executable" ]] || fail "Release executable not found: $executable"
    [[ -f "$framework_binary" ]] || fail "Bundled Sparkle framework binary not found: $framework_binary"

    if otool -L "$executable" | grep -q "@rpath/Sparkle.framework/Versions/B/Sparkle"; then
        log_success "Verified Sparkle framework load command"
    else
        fail "Release executable is not linked against @rpath/Sparkle.framework/Versions/B/Sparkle"
    fi

    if otool -l "$executable" | grep -q "@executable_path/../Frameworks"; then
        log_success "Verified executable rpath includes Contents/Frameworks"
    else
        fail "Release executable is missing @executable_path/../Frameworks rpath for Sparkle.framework"
    fi
}

sign_framework_nested_code() {
    local framework_path="$1"
    local sparkle_base="$framework_path/Versions/B"
    local sparkle_autoupdate="$framework_path/Versions/B/Autoupdate"
    local nested_bundle=""

    shopt -s nullglob
    for nested_bundle in "$sparkle_base/XPCServices"/*.xpc "$sparkle_base/Updater.app"; do
        codesign_with_identity "$nested_bundle"
        log_success "Signed nested Sparkle bundle $(basename "$nested_bundle")"
    done
    shopt -u nullglob

    if [[ -x "$sparkle_autoupdate" ]]; then
        codesign_with_identity "$sparkle_autoupdate"
        log_success "Signed Sparkle Autoupdate helper"
    fi
}

for arg in "$@"; do
    case "$arg" in
        --no-sign)
            SIGN_APP=false
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            fail "Unknown argument: $arg"
            ;;
    esac
done

log_step "Pre-flight checks"

[[ -f "$PROJECT_DIR/Package.swift" ]] || fail "Package.swift not found. Run from the WorkSpaces repo directory."
log_success "Package.swift found"

if [[ "$SIGN_APP" == true ]]; then
    if [[ -f "$SIGNING_CONFIG" ]]; then
        # shellcheck disable=SC1090
        source "$SIGNING_CONFIG"
        log_success "Loaded signing configuration from $SIGNING_CONFIG"
    elif [[ -n "${SIGNING_IDENTITY:-}" ]]; then
        log_success "Using signing configuration from environment"
    else
        log_warning "signing-config.sh not found - building without code signing"
        log_warning "For local signing, copy scripts/signing-config.sh.template to scripts/signing-config.sh"
        log_warning "For GitHub Actions release setup, use ./scripts/setup-release-secrets.sh (see RELEASING.md)"
        SIGN_APP=false
    fi
fi

if [[ "$SIGN_APP" == true ]]; then
    prepare_signing_assets
fi

log_step "Building release binary"

cd "$PROJECT_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

swift build -c release 2>&1 | while read -r line; do
    if [[ "$line" == *"error:"* ]] || [[ "$line" == *"warning:"* ]]; then
        echo "$line"
    elif [[ "$line" == *"Build complete"* ]]; then
        echo "$line"
    fi
done

[[ -f ".build/release/$EXECUTABLE_NAME" ]] || fail "Build failed - executable not found"
log_success "Build complete"

log_step "Creating app bundle"

mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
mkdir -p "$APP_BUNDLE/Contents/Helpers"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp ".build/release/$EXECUTABLE_NAME" "$APP_BUNDLE/Contents/MacOS/"
log_success "Copied executable"

if [[ -f ".build/release/$CLI_NAME" ]]; then
    cp ".build/release/$CLI_NAME" "$APP_BUNDLE/$CLI_BUNDLE_RELATIVE_PATH"
    log_success "Copied CLI launcher"
fi

INFO_PLIST="Sources/WorkspaceManager/Resources/Info.plist"
[[ -f "$INFO_PLIST" ]] || fail "Info.plist not found at $INFO_PLIST"
cp "$INFO_PLIST" "$APP_BUNDLE/Contents/"
log_success "Copied Info.plist"

PRIVACY_MANIFEST="Sources/WorkspaceManager/Resources/PrivacyInfo.xcprivacy"
if [[ -f "$PRIVACY_MANIFEST" ]]; then
    cp "$PRIVACY_MANIFEST" "$APP_BUNDLE/Contents/Resources/"
    log_success "Copied PrivacyInfo.xcprivacy"
fi

SPM_RESOURCES=".build/release/WorkspaceManager_WorkspaceManager.bundle"
if [[ -d "$SPM_RESOURCES" ]]; then
    cp -R "$SPM_RESOURCES"/* "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || true
    log_success "Copied SPM resources"
fi

SPARKLE_FRAMEWORK=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ -d "$SPARKLE_FRAMEWORK" ]]; then
    cp -R "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"
    log_success "Copied Sparkle.framework"
else
    fail "Sparkle.framework not found at $SPARKLE_FRAMEWORK; run swift package resolve"
fi

if GHOSTTY_SHARE_DIR_RESOLVED="$(resolve_ghostty_share_dir)"; then
    cp -R "$GHOSTTY_SHARE_DIR_RESOLVED"/* "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || true
    log_success "Copied Ghostty resources from $GHOSTTY_SHARE_DIR_RESOLVED"
else
    log_warning "Ghostty share resources not found; packaged shell integration may be degraded"
fi

ASSETS_DIR="Sources/WorkspaceManager/Resources/Assets.xcassets"
if [[ -d "$ASSETS_DIR" ]] && command -v actool >/dev/null 2>&1; then
    log_step "Compiling asset catalog"
    ASSET_INFO_PLIST="$BUILD_DIR/AssetInfo.plist"
    rm -f "$ASSET_INFO_PLIST"

    actool --compile "$APP_BUNDLE/Contents/Resources" \
           --platform macosx \
           --minimum-deployment-target 14.0 \
           --app-icon AppIcon \
           --output-partial-info-plist "$ASSET_INFO_PLIST" \
           "$ASSETS_DIR" 2>/dev/null || log_warning "Asset compilation had warnings"

    if [[ -f "$APP_BUNDLE/Contents/Resources/Assets.car" ]]; then
        log_success "Compiled Assets.car"
    fi

    merge_icon_metadata "$ASSET_INFO_PLIST" "$APP_BUNDLE/Contents/Info.plist"
fi

echo -n "APPL????" >"$APP_BUNDLE/Contents/PkgInfo"
log_success "Created PkgInfo"

if [[ "$SIGN_APP" == true ]]; then
    cp "$PROVISIONING_PROFILE_PATH" "$APP_BUNDLE/Contents/embedded.provisionprofile"
    log_success "Embedded provisioning profile"
fi

if [[ "$SIGN_APP" == true ]] && [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    log_step "Code signing"

    if [[ -f "$APP_BUNDLE/$CLI_BUNDLE_RELATIVE_PATH" ]]; then
        codesign_with_identity "$APP_BUNDLE/$CLI_BUNDLE_RELATIVE_PATH"
        log_success "Signed bundled CLI launcher"
    fi

    if [[ -d "$APP_BUNDLE/Contents/Frameworks" ]]; then
        local_framework=""
        shopt -s nullglob
        for local_framework in "$APP_BUNDLE/Contents/Frameworks"/*; do
            sign_framework_nested_code "$local_framework"
            codesign_with_identity "$local_framework"
        done
        shopt -u nullglob
        log_success "Signed embedded frameworks"
    fi

    codesign_with_identity "$APP_BUNDLE" --entitlements "$SIGNING_ENTITLEMENTS_PLIST"
    log_success "Signed app bundle with provisioning-aware entitlements"

    log_step "Verifying signature"
    codesign --verify --deep --strict --verbose=1 "$APP_BUNDLE"
    log_success "Signature verified"

    verify_signed_keychain_access
    verify_release_bundle_signing

    spctl --assess --type execute --verbose "$APP_BUNDLE" 2>&1 || \
        log_warning "Gatekeeper check failed - app needs notarization for distribution"
else
    log_warning "Skipping code signing"
fi

verify_sparkle_bundle_linkage

echo ""
echo "============================================================================"
echo -e "${GREEN}Build complete!${NC}"
echo "============================================================================"
echo ""
echo "Output: $APP_BUNDLE"
echo "Size:   $(du -sh "$APP_BUNDLE" | cut -f1)"
if [[ "$SIGN_APP" == true ]]; then
    echo "Keychain: data protection keychain enabled for $EXPECTED_KEYCHAIN_GROUP"
else
    echo "Keychain: runtime legacy-keychain fallback (unsigned / ad-hoc build)"
fi
echo ""

if [[ "$SIGN_APP" == true ]]; then
    echo "Next steps for distribution:"
    echo "  1. Run ./scripts/notarize.sh to notarize and create DMG"
    echo ""
else
    echo "Next steps:"
    echo "  1. Set up scripts/signing-config.sh with SIGNING_IDENTITY and PROVISIONING_PROFILE_PATH"
    echo "  2. Re-run with signing enabled"
    echo "  3. Run ./scripts/notarize.sh for notarization"
    echo ""
    echo "For local testing, you can run the unsigned app directly:"
    echo "  open $APP_BUNDLE"
fi
