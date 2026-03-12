#!/bin/bash
# ============================================================================
# verify-app-keychain-signing.sh - Verify packaged app keychain signing state
# ============================================================================
#
# Checks that a packaged .app bundle:
#   1. embeds a provisioning profile
#   2. is signed with application/team identifier entitlements
#   3. claims the expected keychain access group for its bundle identifier
#
# Usage:
#   ./scripts/verify-app-keychain-signing.sh build/WorkspaceManager.app
#
# ============================================================================

set -euo pipefail

APP_BUNDLE="${1:-}"
PLIST_BUDDY="/usr/libexec/PlistBuddy"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/workspaces-keychain-signing.XXXXXX")"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

usage() {
    cat <<'EOF'
Usage: ./scripts/verify-app-keychain-signing.sh <WorkspaceManager.app>

Verifies that the app bundle is provisioned and signed for the data protection
keychain. Exits non-zero if the embedded provisioning profile or signed
entitlements do not authorize the expected keychain access group.
EOF
}

fail() {
    echo "[verify-app-keychain-signing] ERROR: $*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
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

array_contains_value() {
    local expected="$1"
    shift

    local item=""
    for item in "$@"; do
        [[ "$item" == "$expected" ]] && return 0
    done

    return 1
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

extract_signed_entitlements() {
    local app_bundle="$1"
    local raw_output="$TMP_DIR/codesign-entitlements.txt"
    local entitlements_plist="$TMP_DIR/signed-entitlements.plist"

    if ! codesign -d --entitlements :- "$app_bundle" >"$raw_output" 2>&1; then
        cat "$raw_output" >&2 || true
        fail "Failed to read signed entitlements from $app_bundle"
    fi

    sed -n '/^<?xml/,/^<\/plist>/p' "$raw_output" >"$entitlements_plist"
    [[ -s "$entitlements_plist" ]] || fail "Signed entitlements plist not found in codesign output"

    printf '%s\n' "$entitlements_plist"
}

[[ $# -eq 1 ]] || {
    usage
    exit 1
}

require_cmd security
require_cmd codesign
[[ -x "$PLIST_BUDDY" ]] || fail "PlistBuddy not found at $PLIST_BUDDY"

APP_BUNDLE="${APP_BUNDLE/#\~/$HOME}"
[[ -d "$APP_BUNDLE" ]] || fail "App bundle not found: $APP_BUNDLE"

INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
EMBEDDED_PROFILE="$APP_BUNDLE/Contents/embedded.provisionprofile"
PROFILE_PLIST="$TMP_DIR/embedded-profile.plist"

[[ -f "$INFO_PLIST" ]] || fail "Missing Info.plist in app bundle"
[[ -f "$EMBEDDED_PROFILE" ]] || fail "Missing embedded provisioning profile at $EMBEDDED_PROFILE"

if ! security cms -D -i "$EMBEDDED_PROFILE" >"$PROFILE_PLIST"; then
    fail "Failed to decode provisioning profile at $EMBEDDED_PROFILE"
fi

BUNDLE_ID="$(plist_print "$INFO_PLIST" "CFBundleIdentifier")"
[[ -n "$BUNDLE_ID" ]] || fail "CFBundleIdentifier missing from $INFO_PLIST"

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

PROFILE_KEYCHAIN_GROUPS=()
while IFS= read -r keychain_group; do
    PROFILE_KEYCHAIN_GROUPS+=("$keychain_group")
done < <(plist_array_values "$PROFILE_PLIST" "Entitlements:keychain-access-groups")
(( ${#PROFILE_KEYCHAIN_GROUPS[@]} > 0 )) || fail "Provisioning profile is missing keychain-access-groups"

APP_ID_PREFIX="${PROFILE_APPLICATION_IDENTIFIER%%.*}"
[[ "$APP_ID_PREFIX" != "$PROFILE_APPLICATION_IDENTIFIER" ]] || fail "Provisioning profile application-identifier is malformed: $PROFILE_APPLICATION_IDENTIFIER"

EXPECTED_APPLICATION_IDENTIFIER="$APP_ID_PREFIX.$BUNDLE_ID"
EXPECTED_KEYCHAIN_GROUP="$APP_ID_PREFIX.$BUNDLE_ID"

pattern_matches_value "$EXPECTED_APPLICATION_IDENTIFIER" "$PROFILE_APPLICATION_IDENTIFIER" \
    || fail "Provisioning profile does not authorize bundle identifier $BUNDLE_ID"

array_authorizes_value "$EXPECTED_KEYCHAIN_GROUP" "${PROFILE_KEYCHAIN_GROUPS[@]}" \
    || fail "Provisioning profile does not authorize keychain group $EXPECTED_KEYCHAIN_GROUP"

SIGNED_ENTITLEMENTS_PLIST="$(extract_signed_entitlements "$APP_BUNDLE")"

SIGNED_APPLICATION_IDENTIFIER="$(plist_print "$SIGNED_ENTITLEMENTS_PLIST" "com.apple.application-identifier")"
if [[ -z "$SIGNED_APPLICATION_IDENTIFIER" ]]; then
    SIGNED_APPLICATION_IDENTIFIER="$(plist_print "$SIGNED_ENTITLEMENTS_PLIST" "application-identifier")"
fi
[[ "$SIGNED_APPLICATION_IDENTIFIER" == "$EXPECTED_APPLICATION_IDENTIFIER" ]] \
    || fail "Signed application identifier mismatch: expected $EXPECTED_APPLICATION_IDENTIFIER, got ${SIGNED_APPLICATION_IDENTIFIER:-<missing>}"

SIGNED_TEAM_ID="$(plist_print "$SIGNED_ENTITLEMENTS_PLIST" "com.apple.developer.team-identifier")"
[[ "$SIGNED_TEAM_ID" == "$PROFILE_TEAM_ID" ]] \
    || fail "Signed team identifier mismatch: expected $PROFILE_TEAM_ID, got ${SIGNED_TEAM_ID:-<missing>}"

SIGNED_KEYCHAIN_GROUPS=()
while IFS= read -r signed_group; do
    SIGNED_KEYCHAIN_GROUPS+=("$signed_group")
done < <(plist_array_values "$SIGNED_ENTITLEMENTS_PLIST" "keychain-access-groups")
(( ${#SIGNED_KEYCHAIN_GROUPS[@]} > 0 )) || fail "Signed entitlements are missing keychain-access-groups"

array_contains_value "$EXPECTED_KEYCHAIN_GROUP" "${SIGNED_KEYCHAIN_GROUPS[@]}" \
    || fail "Signed entitlements do not include keychain group $EXPECTED_KEYCHAIN_GROUP"

echo "Verified data protection keychain signing for $APP_BUNDLE ($EXPECTED_KEYCHAIN_GROUP)"
