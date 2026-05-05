#!/bin/bash
# Generate and validate release-manifest.json for published WorkSpaces assets.

set -euo pipefail

PLIST_BUDDY="/usr/libexec/PlistBuddy"

fail() {
    echo "[release-manifest] ERROR: $*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

file_size() {
    local path="$1"
    if stat -f %z "$path" >/dev/null 2>&1; then
        stat -f %z "$path"
    else
        stat -c %s "$path"
    fi
}

file_sha256() {
    shasum -a 256 "$1" | awk '{print $1}'
}

plist_print() {
    local plist_path="$1"
    local key_path="$2"
    "$PLIST_BUDDY" -c "Print :$key_path" "$plist_path" 2>/dev/null || true
}

usage() {
    cat <<'EOF'
Usage:
  scripts/release-manifest.sh generate --output <release-manifest.json> --commit <sha> --tag <tag> --version <version> --build <build> --app <WorkSpaces.app> --dmg <dmg> --latest-dmg <dmg> --appcast <appcast.xml> --team-id <team>
  scripts/release-manifest.sh validate --manifest <release-manifest.json> --commit <sha> --tag <tag> --version <version> --build <build> --dmg <dmg> --latest-dmg <dmg> --appcast <appcast.xml> --bundle-id <id> --team-id <team> --sparkle-public-key <key>
EOF
}

parse_options() {
    OUTPUT=""
    COMMIT=""
    TAG=""
    VERSION=""
    BUILD=""
    APP=""
    DMG=""
    LATEST_DMG=""
    APPCAST=""
    TEAM_ID=""
    MANIFEST=""
    BUNDLE_ID=""
    SPARKLE_PUBLIC_KEY=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output)
                [[ $# -ge 2 ]] || fail "$1 requires a value"
                OUTPUT="$2"
                shift 2
                ;;
            --commit)
                [[ $# -ge 2 ]] || fail "$1 requires a value"
                COMMIT="$2"
                shift 2
                ;;
            --tag)
                [[ $# -ge 2 ]] || fail "$1 requires a value"
                TAG="$2"
                shift 2
                ;;
            --version)
                [[ $# -ge 2 ]] || fail "$1 requires a value"
                VERSION="$2"
                shift 2
                ;;
            --build)
                [[ $# -ge 2 ]] || fail "$1 requires a value"
                BUILD="$2"
                shift 2
                ;;
            --app)
                [[ $# -ge 2 ]] || fail "$1 requires a value"
                APP="$2"
                shift 2
                ;;
            --dmg)
                [[ $# -ge 2 ]] || fail "$1 requires a value"
                DMG="$2"
                shift 2
                ;;
            --latest-dmg)
                [[ $# -ge 2 ]] || fail "$1 requires a value"
                LATEST_DMG="$2"
                shift 2
                ;;
            --appcast)
                [[ $# -ge 2 ]] || fail "$1 requires a value"
                APPCAST="$2"
                shift 2
                ;;
            --team-id)
                [[ $# -ge 2 ]] || fail "$1 requires a value"
                TEAM_ID="$2"
                shift 2
                ;;
            --manifest)
                [[ $# -ge 2 ]] || fail "$1 requires a value"
                MANIFEST="$2"
                shift 2
                ;;
            --bundle-id)
                [[ $# -ge 2 ]] || fail "$1 requires a value"
                BUNDLE_ID="$2"
                shift 2
                ;;
            --sparkle-public-key)
                [[ $# -ge 2 ]] || fail "$1 requires a value"
                SPARKLE_PUBLIC_KEY="$2"
                shift 2
                ;;
            *)
                fail "Unknown argument: $1"
                ;;
        esac
    done
}

require_value() {
    local label="$1"
    local value="$2"
    [[ -n "$value" ]] || fail "Missing required $label"
}

assert_file() {
    local path="$1"
    [[ -f "$path" ]] || fail "File not found: $path"
}

generate_manifest() {
    parse_options "$@"
    require_cmd jq
    require_cmd shasum
    require_cmd awk
    [[ -x "$PLIST_BUDDY" ]] || fail "PlistBuddy not found at $PLIST_BUDDY"

    require_value --output "$OUTPUT"
    require_value --commit "$COMMIT"
    require_value --tag "$TAG"
    require_value --version "$VERSION"
    require_value --build "$BUILD"
    require_value --app "$APP"
    require_value --dmg "$DMG"
    require_value --latest-dmg "$LATEST_DMG"
    require_value --appcast "$APPCAST"
    require_value --team-id "$TEAM_ID"

    assert_file "$APP/Contents/Info.plist"
    assert_file "$DMG"
    assert_file "$LATEST_DMG"
    assert_file "$APPCAST"

    local bundle_id sparkle_public_key
    bundle_id="$(plist_print "$APP/Contents/Info.plist" "CFBundleIdentifier")"
    sparkle_public_key="$(plist_print "$APP/Contents/Info.plist" "SUPublicEDKey")"
    [[ -n "$bundle_id" ]] || fail "CFBundleIdentifier missing from $APP/Contents/Info.plist"
    [[ -n "$sparkle_public_key" ]] || fail "SUPublicEDKey missing from $APP/Contents/Info.plist"

    mkdir -p "$(dirname "$OUTPUT")"
    jq -n \
        --arg commitSha "$COMMIT" \
        --arg tag "$TAG" \
        --arg version "$VERSION" \
        --arg build "$BUILD" \
        --arg bundleId "$bundle_id" \
        --arg teamId "$TEAM_ID" \
        --arg sparklePublicEdKey "$sparkle_public_key" \
        --arg dmgName "$(basename "$DMG")" \
        --arg dmgSha "$(file_sha256 "$DMG")" \
        --argjson dmgSize "$(file_size "$DMG")" \
        --arg latestName "$(basename "$LATEST_DMG")" \
        --arg latestSha "$(file_sha256 "$LATEST_DMG")" \
        --argjson latestSize "$(file_size "$LATEST_DMG")" \
        --arg appcastName "$(basename "$APPCAST")" \
        --arg appcastSha "$(file_sha256 "$APPCAST")" \
        --argjson appcastSize "$(file_size "$APPCAST")" \
        '{
          schemaVersion: 1,
          commitSha: $commitSha,
          tag: $tag,
          version: $version,
          build: $build,
          bundleId: $bundleId,
          teamId: $teamId,
          sparklePublicEdKey: $sparklePublicEdKey,
          assets: {
            dmg: { name: $dmgName, sha256: $dmgSha, size: $dmgSize },
            latestDmg: { name: $latestName, sha256: $latestSha, size: $latestSize },
            appcast: { name: $appcastName, sha256: $appcastSha, size: $appcastSize }
          }
        }' >"$OUTPUT"

    echo "Generated release manifest: $OUTPUT"
}

assert_json_string() {
    local manifest="$1"
    local expression="$2"
    local expected="$3"
    local label="$4"
    local actual
    actual="$(jq -r "$expression // empty" "$manifest")"
    [[ "$actual" == "$expected" ]] || fail "$label mismatch: expected $expected, got ${actual:-<missing>}"
}

assert_asset() {
    local manifest="$1"
    local key="$2"
    local path="$3"
    local name sha size
    name="$(basename "$path")"
    sha="$(file_sha256 "$path")"
    size="$(file_size "$path")"
    assert_json_string "$manifest" ".assets.$key.name" "$name" "$key name"
    assert_json_string "$manifest" ".assets.$key.sha256" "$sha" "$key sha256"
    assert_json_string "$manifest" ".assets.$key.size | tostring" "$size" "$key size"
}

validate_manifest() {
    parse_options "$@"
    require_cmd jq
    require_cmd shasum
    require_cmd awk

    require_value --manifest "$MANIFEST"
    require_value --commit "$COMMIT"
    require_value --tag "$TAG"
    require_value --version "$VERSION"
    require_value --build "$BUILD"
    require_value --dmg "$DMG"
    require_value --latest-dmg "$LATEST_DMG"
    require_value --appcast "$APPCAST"
    require_value --bundle-id "$BUNDLE_ID"
    require_value --team-id "$TEAM_ID"
    require_value --sparkle-public-key "$SPARKLE_PUBLIC_KEY"

    assert_file "$MANIFEST"
    assert_file "$DMG"
    assert_file "$LATEST_DMG"
    assert_file "$APPCAST"

    jq -e '.schemaVersion == 1 and (.assets | type == "object")' "$MANIFEST" >/dev/null \
        || fail "Unsupported or malformed manifest schema"
    assert_json_string "$MANIFEST" ".commitSha" "$COMMIT" "commit SHA"
    assert_json_string "$MANIFEST" ".tag" "$TAG" "tag"
    assert_json_string "$MANIFEST" ".version" "$VERSION" "version"
    assert_json_string "$MANIFEST" ".build" "$BUILD" "build"
    assert_json_string "$MANIFEST" ".bundleId" "$BUNDLE_ID" "bundle ID"
    assert_json_string "$MANIFEST" ".teamId" "$TEAM_ID" "team ID"
    assert_json_string "$MANIFEST" ".sparklePublicEdKey" "$SPARKLE_PUBLIC_KEY" "Sparkle public key"
    assert_asset "$MANIFEST" dmg "$DMG"
    assert_asset "$MANIFEST" latestDmg "$LATEST_DMG"
    assert_asset "$MANIFEST" appcast "$APPCAST"

    echo "Validated release manifest: $MANIFEST"
}

COMMAND="${1:-}"
case "$COMMAND" in
    generate)
        shift
        generate_manifest "$@"
        ;;
    validate)
        shift
        validate_manifest "$@"
        ;;
    --help|-h|"")
        usage
        [[ -n "$COMMAND" ]] || exit 1
        ;;
    *)
        fail "Unknown command: $COMMAND"
        ;;
esac
