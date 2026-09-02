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
NOTES_ONLY=false
NOTES_VERSION=""

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

# Renders the inline markdown subset CHANGELOG.md actually uses — **strong**,
# `code`, and [text](url) for http/https/mailto — into HTML. Input is already
# HTML-escaped, so the tags emitted here are the only markup that can reach
# Sparkle. Anything unrecognized (single asterisks, unclosed pairs, other URL
# schemes) is left as literal text rather than guessed at.
render_inline_markdown() {
    awk '
        function render(s,   out, n, i, c, rest, endpos, urlrest, uclose, url) {
            out = ""
            n = length(s)
            i = 1
            while (i <= n) {
                c = substr(s, i, 1)
                if (c == "`") {
                    rest = substr(s, i + 1)
                    endpos = index(rest, "`")
                    if (endpos > 1) {
                        out = out "<code>" substr(rest, 1, endpos - 1) "</code>"
                        i += endpos + 1
                        continue
                    }
                } else if (substr(s, i, 2) == "**") {
                    rest = substr(s, i + 2)
                    endpos = index(rest, "**")
                    if (endpos > 1) {
                        out = out "<strong>" render(substr(rest, 1, endpos - 1)) "</strong>"
                        i += endpos + 3
                        continue
                    }
                } else if (c == "[") {
                    rest = substr(s, i + 1)
                    endpos = index(rest, "]")
                    if (endpos > 1 && substr(rest, endpos + 1, 1) == "(") {
                        urlrest = substr(rest, endpos + 2)
                        uclose = index(urlrest, ")")
                        url = substr(urlrest, 1, uclose - 1)
                        if (uclose > 1 && url ~ /^(https?:\/\/|mailto:)[^ ]+$/) {
                            out = out "<a href=\"" url "\">" render(substr(rest, 1, endpos - 1)) "</a>"
                            i += endpos + uclose + 2
                            continue
                        }
                    }
                }
                out = out c
                i++
            }
            return out
        }
        { print render($0) }
    '
}

inline_html() {
    printf '%s\n' "$1" | html_escape | render_inline_markdown
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
    local kind=""
    local content=""
    local in_list=false
    local paragraph=""

    printf '        <h2>WorkSpaces %s</h2>\n' "$(printf '%s' "$short_version" | html_escape)"

    while IFS= read -r line || [[ -n "$line" ]]; do
        kind="prose"
        content="$line"
        if [[ "$line" =~ ^###[[:space:]]+(.+)$ ]]; then
            kind="heading"
            content="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^-[[:space:]]+(.+)$ ]]; then
            kind="item"
            content="${BASH_REMATCH[1]}"
        elif [[ -z "${line//[[:space:]]/}" ]]; then
            kind="blank"
        fi

        # Changelog prose is soft-wrapped for GitHub, so consecutive prose lines
        # are one paragraph; a <p> per source line renders the intro as a column
        # of fragments in the update dialog. Anything else ends the paragraph,
        # and anything but another item ends an open list.
        if [[ "$kind" != "prose" && -n "$paragraph" ]]; then
            printf '        <p>%s</p>\n' "$(inline_html "$paragraph")"
            paragraph=""
        fi
        if [[ "$kind" != "item" && "$in_list" == true ]]; then
            printf '        </ul>\n'
            in_list=false
        fi

        case "$kind" in
            heading)
                printf '        <h3>%s</h3>\n' "$(inline_html "$content")"
                ;;
            item)
                if [[ "$in_list" == false ]]; then
                    printf '        <ul>\n'
                    in_list=true
                fi
                printf '          <li>%s</li>\n' "$(inline_html "$content")"
                ;;
            prose)
                paragraph+="${paragraph:+ }$content"
                ;;
        esac
    done

    if [[ -n "$paragraph" ]]; then
        printf '        <p>%s</p>\n' "$(inline_html "$paragraph")"
    fi
    if [[ "$in_list" == true ]]; then
        printf '        </ul>\n'
    fi
}

usage() {
    cat <<'EOF'
Usage:
  scripts/generate-sparkle-appcast.sh --dmg <path> --tag <tag> [options]
  scripts/generate-sparkle-appcast.sh --notes-only --version <version> [--changelog <path>]

Options:
  --app <path>       App bundle used for version metadata (default: build/WorkSpaces.app)
  --output <path>    Output appcast path (default: build/appcast.xml)
  --changelog <path> Changelog used for embedded release notes (default: CHANGELOG.md)
  --repo <owner/repo> GitHub repository for release asset URLs (default: GITHUB_REPOSITORY or fairchild/workspaces)
  --notes-only       Print the rendered release-notes HTML for --version and exit.
                     This is exactly what Sparkle shows in the update dialog, so
                     it previews a release without a DMG, app bundle, or key.
  --version <ver>    Changelog version that --notes-only renders (e.g. 0.25.0)
  --help            Show this help

Required environment:
  SPARKLE_PRIVATE_KEY  Private EdDSA key exported by Sparkle generate_keys -x.
                       Not needed for --notes-only.
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
        --notes-only)
            NOTES_ONLY=true
            shift
            ;;
        --version)
            NOTES_VERSION="${2:-}"
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

if [[ "$NOTES_ONLY" == true ]]; then
    [[ -n "$NOTES_VERSION" ]] || fail "--notes-only requires --version"
    [[ -f "$CHANGELOG_PATH" ]] || fail "CHANGELOG.md not found: $CHANGELOG_PATH"
    if ! NOTES_ENTRY="$(extract_changelog_section "$NOTES_VERSION")"; then
        fail "CHANGELOG.md does not contain release notes for WorkSpaces $NOTES_VERSION"
    fi
    printf '%s\n' "$NOTES_ENTRY" | render_release_notes_html "$NOTES_VERSION"
    exit 0
fi

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
