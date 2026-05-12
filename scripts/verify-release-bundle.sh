#!/bin/bash
# ============================================================================
# verify-release-bundle.sh - Verify Developer ID signing across app code objects
# ============================================================================
#
# Checks that a packaged .app bundle and its nested Mach-O code objects are
# signed for Developer ID distribution before notarization.
#
# Usage:
#   ./scripts/verify-release-bundle.sh build/WorkSpaces.app
#
# ============================================================================

set -euo pipefail

APP_BUNDLE="${1:-}"
EXPECTED_BUNDLE_NAME="WorkSpaces.app"
EXPECTED_DISPLAY_NAME="WorkSpaces"
EXPECTED_EXECUTABLE_NAME="WorkspaceManager"
PLIST_BUDDY="/usr/libexec/PlistBuddy"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/workspaces-release-bundle.XXXXXX")"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

usage() {
    cat <<'EOF'
Usage: ./scripts/verify-release-bundle.sh <WorkSpaces.app>

Verifies that the packaged app bundle and nested Mach-O code objects are signed
with a non-ad-hoc Developer ID signature and a real team identifier. Also
verifies release identity metadata and bundled Ghostty resources required at
runtime are present.
EOF
}

fail() {
    echo "[verify-release-bundle] ERROR: $*" >&2
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

verify_bundle_identity() {
    local bundle_path="$1"
    local info_plist="$bundle_path/Contents/Info.plist"
    local bundle_name=""
    local display_name=""
    local bundle_display_name=""
    local executable_name=""

    bundle_name="$(basename "$bundle_path")"
    [[ "$bundle_name" == "$EXPECTED_BUNDLE_NAME" ]] \
        || fail "Release app bundle must be named $EXPECTED_BUNDLE_NAME (got $bundle_name)"

    [[ -f "$info_plist" ]] || fail "Missing Info.plist in app bundle"

    bundle_display_name="$(plist_print "$info_plist" "CFBundleDisplayName")"
    [[ "$bundle_display_name" == "$EXPECTED_DISPLAY_NAME" ]] \
        || fail "CFBundleDisplayName must be $EXPECTED_DISPLAY_NAME (got ${bundle_display_name:-<missing>})"

    display_name="$(plist_print "$info_plist" "CFBundleName")"
    [[ "$display_name" == "$EXPECTED_DISPLAY_NAME" ]] \
        || fail "CFBundleName must be $EXPECTED_DISPLAY_NAME (got ${display_name:-<missing>})"

    executable_name="$(plist_print "$info_plist" "CFBundleExecutable")"
    [[ "$executable_name" == "$EXPECTED_EXECUTABLE_NAME" ]] \
        || fail "CFBundleExecutable must be $EXPECTED_EXECUTABLE_NAME (got ${executable_name:-<missing>})"

    [[ -x "$bundle_path/Contents/MacOS/$EXPECTED_EXECUTABLE_NAME" ]] \
        || fail "Expected executable missing: Contents/MacOS/$EXPECTED_EXECUTABLE_NAME"
}

is_mach_o() {
    local candidate="$1"
    file -b "$candidate" 2>/dev/null | grep -q 'Mach-O'
}

verify_codesign_identity() {
    local target="$1"
    local label="$2"
    local report_file="$TMP_DIR/report-$(basename "$target" | tr ' /' '__').txt"
    local team_identifier=""

    if ! codesign -dvv "$target" >"$report_file" 2>&1; then
        cat "$report_file" >&2 || true
        fail "Failed to inspect signature for $label"
    fi

    if grep -Eq '^Signature=adhoc$|flags=.*adhoc' "$report_file"; then
        cat "$report_file" >&2 || true
        fail "$label is ad-hoc signed"
    fi

    team_identifier="$(sed -n 's/^TeamIdentifier=//p' "$report_file" | head -n 1)"
    if [[ -z "$team_identifier" ]] || [[ "$team_identifier" == "not set" ]]; then
        cat "$report_file" >&2 || true
        fail "$label is missing a TeamIdentifier"
    fi

    if ! grep -q '^Authority=Developer ID Application:' "$report_file"; then
        cat "$report_file" >&2 || true
        fail "$label is not signed with a Developer ID Application authority"
    fi
}

collect_code_objects() {
    local root="$1"
    local candidate=""

    [[ -d "$root" ]] || return 0

    while IFS= read -r -d '' candidate; do
        [[ -f "$candidate" ]] || continue
        if ! is_mach_o "$candidate"; then
            continue
        fi
        if grep -Fqx "$candidate" "$CODE_OBJECTS_FILE" 2>/dev/null; then
            continue
        fi
        printf '%s\n' "$candidate" >>"$CODE_OBJECTS_FILE"
    done < <(find "$root" -type f -print0)
}

[[ $# -eq 1 ]] || {
    usage
    exit 1
}

require_cmd codesign
require_cmd file
require_cmd find
[[ -x "$PLIST_BUDDY" ]] || fail "PlistBuddy not found at $PLIST_BUDDY"

APP_BUNDLE="${APP_BUNDLE/#\~/$HOME}"
[[ -d "$APP_BUNDLE" ]] || fail "App bundle not found: $APP_BUNDLE"
verify_bundle_identity "$APP_BUNDLE"
[[ -d "$APP_BUNDLE/Contents/Resources/ghostty" ]] || fail "Missing Ghostty resources directory"
[[ -d "$APP_BUNDLE/Contents/Resources/terminfo" ]] || fail "Missing bundled terminfo directory"
[[ -f "$APP_BUNDLE/Contents/Resources/HookForwarders/event-forwarder.sh" ]] || fail "Missing Claude hook event forwarder"
[[ -f "$APP_BUNDLE/Contents/Resources/HookForwarders/statusline.sh" ]] || fail "Missing Claude status-line forwarder"

CODE_OBJECTS_FILE="$TMP_DIR/code-objects.txt"
: >"$CODE_OBJECTS_FILE"
SEARCH_ROOTS=(
    "$APP_BUNDLE/Contents/MacOS"
    "$APP_BUNDLE/Contents/Helpers"
    "$APP_BUNDLE/Contents/Frameworks"
    "$APP_BUNDLE/Contents/PlugIns"
    "$APP_BUNDLE/Contents/Library/XPCServices"
    "$APP_BUNDLE/Contents/Library/LoginItems"
)

for search_root in "${SEARCH_ROOTS[@]}"; do
    collect_code_objects "$search_root"
done

verify_codesign_identity "$APP_BUNDLE" "$APP_BUNDLE"

CODE_OBJECT_COUNT=0
while IFS= read -r code_object; do
    [[ -n "$code_object" ]] || continue
    CODE_OBJECT_COUNT=$((CODE_OBJECT_COUNT + 1))
    verify_codesign_identity "$code_object" "$code_object"
done <"$CODE_OBJECTS_FILE"

echo "Verified Developer ID signing for $APP_BUNDLE ($CODE_OBJECT_COUNT nested code object(s))"
