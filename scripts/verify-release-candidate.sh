#!/usr/bin/env bash
# Verify the downloaded candidate, including the app inside its notarized DMG.
# This reuses release validators and adds a packaged CLI launch without opening
# the app or depending on a desktop session. It runs before publication approval.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSETS="${1:?Usage: verify-release-candidate.sh <candidate-directory>}"
ASSETS="$(cd "$ASSETS" && pwd)"
cd "$ROOT"
: "${SOURCE:?}" "${TAG:?}" "${CHANNEL:?}" "${VERSION:?}" "${BUILD:?}" "${CANDIDATE_SHA256:?}" "${EXPECTED_TEAM_ID:?}"

uv run --script scripts/release-candidate.py verify --directory "$ASSETS" \
    --source "$SOURCE" --tag "$TAG" --channel "$CHANNEL" \
    --version "$VERSION" --build "$BUILD" --candidate-sha256 "$CANDIDATE_SHA256"

PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Sources/WorkspaceManager/Resources/Info.plist)"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Sources/WorkspaceManager/Resources/Info.plist)"
DMG="$ASSETS/WorkSpaces-$VERSION.dmg"
./scripts/release-manifest.sh validate \
    --manifest "$ASSETS/release-manifest.json" --commit "$SOURCE" --tag "$TAG" \
    --version "$VERSION" --build "$BUILD" --dmg "$DMG" \
    --latest-dmg "$ASSETS/WorkSpaces-latest.dmg" --appcast "$ASSETS/appcast.xml" \
    --bundle-id "$BUNDLE_ID" --team-id "$EXPECTED_TEAM_ID" --sparkle-public-key "$PUBLIC_KEY"
./scripts/verify-sparkle-appcast.swift --appcast "$ASSETS/appcast.xml" --dmg "$DMG" \
    --public-key "$PUBLIC_KEY" --expected-version "$BUILD" --expected-short-version "$VERSION" \
    --expected-url "https://github.com/${GITHUB_REPOSITORY}/releases/download/${TAG}/WorkSpaces-${VERSION}.dmg"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"

MOUNT_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/release-candidate.XXXXXX")"
MOUNT_PATH="$MOUNT_ROOT/mount"
mkdir "$MOUNT_PATH"
mounted=false
completed=false
cleanup() {
    local status=$?
    if [[ "$mounted" == true ]]; then
        hdiutil detach "$MOUNT_PATH" >/dev/null || true
    fi
    rmdir "$MOUNT_PATH" "$MOUNT_ROOT" 2>/dev/null || true
    # macOS bash 3.2 can report zero to EXIT after a nounset abort. Completion
    # must be explicit, as in verify-release-bundle.sh.
    if [[ $status -eq 0 && "$completed" != true ]]; then status=1; fi
    trap - EXIT
    exit "$status"
}
trap cleanup EXIT
hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MOUNT_PATH" >/dev/null
mounted=true
APP="$MOUNT_PATH/WorkSpaces.app"
./scripts/verify-release-bundle.sh "$APP"
ACTUAL_TEAM_ID="$(codesign -dv --verbose=4 "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[[ "$ACTUAL_TEAM_ID" == "$EXPECTED_TEAM_ID" ]] || { echo "Candidate signing team mismatch" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" == "$VERSION" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")" == "$BUILD" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")" == "$PUBLIC_KEY" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP/Contents/Info.plist")" == "https://github.com/${GITHUB_REPOSITORY}/releases/latest/download/appcast.xml" ]]
WORKSPACES_NO_ACTIVATE_ON_LAUNCH=1 python3 - "$APP/Contents/Helpers/workspaces" <<'PY'
import subprocess
import sys

result = subprocess.run([sys.argv[1], "--help"], capture_output=True, text=True, timeout=30, check=True)
assert "workspaces" in result.stdout.lower(), "Packaged CLI did not produce its help output"
print("Packaged CLI launch passed; no GUI activation requested.")
PY
completed=true
