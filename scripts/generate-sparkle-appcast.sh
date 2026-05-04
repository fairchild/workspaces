#!/bin/bash
# ============================================================================
# generate-sparkle-appcast.sh - Generate a signed Sparkle appcast for a DMG
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PLIST_BUDDY="/usr/libexec/PlistBuddy"

DMG_PATH=""
APP_BUNDLE="$PROJECT_DIR/build/WorkSpaces.app"
OUTPUT_PATH="$PROJECT_DIR/build/appcast.xml"
REPO="${GITHUB_REPOSITORY:-fairchild/workspaces}"
TAG=""

usage() {
    cat <<'EOF'
Usage:
  scripts/generate-sparkle-appcast.sh --dmg <path> --tag <tag> [options]

Options:
  --app <path>       App bundle used for version metadata (default: build/WorkSpaces.app)
  --output <path>    Output appcast path (default: build/appcast.xml)
  --repo <owner/repo> GitHub repository for release asset URLs (default: GITHUB_REPOSITORY or fairchild/workspaces)
  --help            Show this help

Required environment:
  SPARKLE_PRIVATE_KEY  Private EdDSA key exported by Sparkle generate_keys -x.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dmg)
            DMG_PATH="${2:-}"
            shift 2
            ;;
        --app)
            APP_BUNDLE="${2:-}"
            shift 2
            ;;
        --output)
            OUTPUT_PATH="${2:-}"
            shift 2
            ;;
        --repo)
            REPO="${2:-}"
            shift 2
            ;;
        --tag)
            TAG="${2:-}"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[[ -n "$DMG_PATH" ]] || { echo "Missing required --dmg path" >&2; exit 2; }
[[ -n "$TAG" ]] || { echo "Missing required --tag" >&2; exit 2; }
[[ -f "$DMG_PATH" ]] || { echo "DMG not found: $DMG_PATH" >&2; exit 1; }
[[ -d "$APP_BUNDLE" ]] || { echo "App bundle not found: $APP_BUNDLE" >&2; exit 1; }
[[ -n "${SPARKLE_PRIVATE_KEY:-}" ]] || {
    echo "SPARKLE_PRIVATE_KEY is required to sign Sparkle update archives" >&2
    exit 1
}

SIGN_UPDATE="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/bin/sign_update"
[[ -x "$SIGN_UPDATE" ]] || {
    echo "Sparkle sign_update tool not found at $SIGN_UPDATE; run swift package resolve" >&2
    exit 1
}

INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
[[ -f "$INFO_PLIST" ]] || { echo "Info.plist not found in app bundle: $INFO_PLIST" >&2; exit 1; }

VERSION="$("$PLIST_BUDDY" -c "Print :CFBundleVersion" "$INFO_PLIST")"
SHORT_VERSION="$("$PLIST_BUDDY" -c "Print :CFBundleShortVersionString" "$INFO_PLIST")"
MIN_SYSTEM_VERSION="$("$PLIST_BUDDY" -c "Print :LSMinimumSystemVersion" "$INFO_PLIST")"
DMG_BASENAME="$(basename "$DMG_PATH")"
DOWNLOAD_URL="https://github.com/$REPO/releases/download/$TAG/$DMG_BASENAME"
RELEASE_URL="https://github.com/$REPO/releases/tag/$TAG"
PUB_DATE="$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")"

SIGNATURE_ATTRIBUTES="$(
    printf "%s" "$SPARKLE_PRIVATE_KEY" \
        | "$SIGN_UPDATE" --ed-key-file - "$DMG_PATH"
)"

mkdir -p "$(dirname "$OUTPUT_PATH")"
cat >"$OUTPUT_PATH" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>WorkSpaces Updates</title>
    <link>https://github.com/$REPO/releases/latest</link>
    <description>Signed WorkSpaces releases.</description>
    <language>en</language>
    <item>
      <title>WorkSpaces $SHORT_VERSION</title>
      <link>$RELEASE_URL</link>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$SHORT_VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_SYSTEM_VERSION</sparkle:minimumSystemVersion>
      <pubDate>$PUB_DATE</pubDate>
      <enclosure url="$DOWNLOAD_URL" $SIGNATURE_ATTRIBUTES type="application/octet-stream" />
      <description><![CDATA[
        <p>See the GitHub release notes for WorkSpaces $SHORT_VERSION.</p>
      ]]></description>
    </item>
  </channel>
</rss>
XML

echo "Generated Sparkle appcast: $OUTPUT_PATH"
