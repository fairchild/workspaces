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
CHANGELOG_PATH="$PROJECT_DIR/CHANGELOG.md"
REPO="${GITHUB_REPOSITORY:-fairchild/workspaces}"
TAG=""

fail() {
    echo "[generate-sparkle-appcast] ERROR: $*" >&2
    exit 1
}

html_escape() {
    sed \
        -e 's/&/\&amp;/g' \
        -e 's/</\&lt;/g' \
        -e 's/>/\&gt;/g' \
        -e 's/"/\&quot;/g'
}

extract_changelog_section() {
    local version="$1"

    awk -v version="$version" '
        /^## \[/ {
            if (found) {
                exit 0
            }
            if (index($0, "## [" version "] - ") == 1) {
                found = 1
                next
            }
        }
        found {
            print
        }
        END {
            if (!found) {
                exit 42
            }
        }
    ' "$CHANGELOG_PATH"
}

render_release_notes_html() {
    local short_version="$1"
    local line=""
    local escaped=""
    local in_list=false

    printf '        <h2>WorkSpaces %s</h2>\n' "$(printf '%s' "$short_version" | html_escape)"

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^###[[:space:]]+(.+)$ ]]; then
            if [[ "$in_list" == true ]]; then
                printf '        </ul>\n'
                in_list=false
            fi
            escaped="$(printf '%s' "${BASH_REMATCH[1]}" | html_escape)"
            printf '        <h3>%s</h3>\n' "$escaped"
            continue
        fi

        if [[ "$line" =~ ^-[[:space:]]+(.+)$ ]]; then
            if [[ "$in_list" == false ]]; then
                printf '        <ul>\n'
                in_list=true
            fi
            escaped="$(printf '%s' "${BASH_REMATCH[1]}" | html_escape)"
            printf '          <li>%s</li>\n' "$escaped"
            continue
        fi

        if [[ -z "${line//[[:space:]]/}" ]]; then
            if [[ "$in_list" == true ]]; then
                printf '        </ul>\n'
                in_list=false
            fi
            continue
        fi

        if [[ "$in_list" == true ]]; then
            printf '        </ul>\n'
            in_list=false
        fi
        escaped="$(printf '%s' "$line" | html_escape)"
        printf '        <p>%s</p>\n' "$escaped"
    done

    if [[ "$in_list" == true ]]; then
        printf '        </ul>\n'
    fi
}

usage() {
    cat <<'EOF'
Usage:
  scripts/generate-sparkle-appcast.sh --dmg <path> --tag <tag> [options]

Options:
  --app <path>       App bundle used for version metadata (default: build/WorkSpaces.app)
  --output <path>    Output appcast path (default: build/appcast.xml)
  --changelog <path> Changelog used for embedded release notes (default: CHANGELOG.md)
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
        --changelog)
            CHANGELOG_PATH="${2:-}"
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

[[ -n "$DMG_PATH" ]] || fail "Missing required --dmg path"
[[ -n "$TAG" ]] || fail "Missing required --tag"
[[ -f "$DMG_PATH" ]] || fail "DMG not found: $DMG_PATH"
[[ -d "$APP_BUNDLE" ]] || fail "App bundle not found: $APP_BUNDLE"
[[ -f "$CHANGELOG_PATH" ]] || fail "CHANGELOG.md not found: $CHANGELOG_PATH"
[[ -n "${SPARKLE_PRIVATE_KEY:-}" ]] || {
    fail "SPARKLE_PRIVATE_KEY is required to sign Sparkle update archives"
}

SIGN_UPDATE="$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/bin/sign_update"

INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
[[ -f "$INFO_PLIST" ]] || fail "Info.plist not found in app bundle: $INFO_PLIST"

VERSION="$("$PLIST_BUDDY" -c "Print :CFBundleVersion" "$INFO_PLIST")"
SHORT_VERSION="$("$PLIST_BUDDY" -c "Print :CFBundleShortVersionString" "$INFO_PLIST")"
MIN_SYSTEM_VERSION="$("$PLIST_BUDDY" -c "Print :LSMinimumSystemVersion" "$INFO_PLIST")"
DMG_BASENAME="$(basename "$DMG_PATH")"
# In the release workflow, REPO comes from GITHUB_REPOSITORY and TAG has passed
# release-version validation. Constrain or XML-escape arbitrary --repo/--tag
# inputs before broadening this script beyond trusted release automation.
DOWNLOAD_URL="https://github.com/$REPO/releases/download/$TAG/$DMG_BASENAME"
RELEASE_URL="https://github.com/$REPO/releases/tag/$TAG"
CHANGELOG_URL="https://github.com/$REPO/blob/$TAG/CHANGELOG.md"
PUB_DATE="$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")"

if ! CHANGELOG_ENTRY="$(extract_changelog_section "$SHORT_VERSION")"; then
    fail "CHANGELOG.md does not contain release notes for WorkSpaces $SHORT_VERSION"
fi
if [[ -z "${CHANGELOG_ENTRY//[[:space:]]/}" ]]; then
    fail "CHANGELOG.md release notes for WorkSpaces $SHORT_VERSION are empty"
fi
RELEASE_NOTES_HTML="$(printf '%s\n' "$CHANGELOG_ENTRY" | render_release_notes_html "$SHORT_VERSION")"

[[ -x "$SIGN_UPDATE" ]] || {
    fail "Sparkle sign_update tool not found at $SIGN_UPDATE; run swift package resolve"
}

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
      <sparkle:fullReleaseNotesLink>$CHANGELOG_URL</sparkle:fullReleaseNotesLink>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$SHORT_VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_SYSTEM_VERSION</sparkle:minimumSystemVersion>
      <pubDate>$PUB_DATE</pubDate>
      <enclosure url="$DOWNLOAD_URL" $SIGNATURE_ATTRIBUTES type="application/octet-stream" />
      <description><![CDATA[
$RELEASE_NOTES_HTML
      ]]></description>
    </item>
  </channel>
</rss>
XML

echo "Generated Sparkle appcast: $OUTPUT_PATH"
