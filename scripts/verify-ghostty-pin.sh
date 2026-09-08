#!/bin/bash
# ============================================================================
# verify-ghostty-pin.sh - Check the built framework against the pinned commit
# ============================================================================
#
# Frameworks/GhosttyKit.xcframework is gitignored, expensive to build, and
# therefore copied between checkouts by hand. Nothing in the source tree
# records which Ghostty commit a copied framework was built at, so moving the
# pin (#1564) leaves older checkouts holding a framework that no longer matches
# their own source with nothing to say so. An incremental Swift build across
# that change links stale code rather than failing, which is the expensive way
# to find out.
#
# build-ghosttykit.sh stamps the commit inside the xcframework after its
# asserts pass. This reads that stamp. A framework built before stamping
# existed carries no stamp, so provenance is unverifiable — that case warns
# rather than fails, except where the archive name alone proves the framework
# predates the current pin.
#
# Usage:
#   ./scripts/verify-ghostty-pin.sh [path/to/GhosttyKit.xcframework]
#
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_GHOSTTYKIT="$SCRIPT_DIR/build-ghosttykit.sh"
FRAMEWORK="${1:-$PROJECT_DIR/Frameworks/GhosttyKit.xcframework}"

fail() {
    echo "[verify-ghostty-pin] ERROR: $1" >&2
    exit 1
}

[[ -x "$BUILD_GHOSTTYKIT" ]] || fail "missing $BUILD_GHOSTTYKIT"

# The pin, the archive name, and the stamp name all live in build-ghosttykit.sh;
# it hands them over rather than having them re-spelled here.
GHOSTTY_COMMIT=""
GHOSTTY_ARCHIVE_NAME=""
GHOSTTY_PIN_STAMP_NAME=""
manifest="$("$BUILD_GHOSTTYKIT" --print-pin)" || fail "could not read the pin manifest from build-ghosttykit.sh"
while IFS='=' read -r key value; do
    case "$key" in
        GHOSTTY_COMMIT) GHOSTTY_COMMIT="$value" ;;
        GHOSTTY_ARCHIVE_NAME) GHOSTTY_ARCHIVE_NAME="$value" ;;
        GHOSTTY_PIN_STAMP_NAME) GHOSTTY_PIN_STAMP_NAME="$value" ;;
    esac
done <<< "$manifest"

[[ -n "$GHOSTTY_COMMIT" && -n "$GHOSTTY_ARCHIVE_NAME" && -n "$GHOSTTY_PIN_STAMP_NAME" ]] ||
    fail "incomplete pin manifest from build-ghosttykit.sh"

recovery="build it with $BUILD_GHOSTTYKIT, or copy Frameworks/GhosttyKit.xcframework from a checkout built at $GHOSTTY_COMMIT"

if [[ ! -d "$FRAMEWORK" ]]; then
    fail "no GhosttyKit.xcframework at $FRAMEWORK; $recovery"
fi

stamp_file="$FRAMEWORK/$GHOSTTY_PIN_STAMP_NAME"
if [[ -f "$stamp_file" ]]; then
    stamped="$(tr -d '[:space:]' < "$stamp_file")"
    if [[ "$stamped" != "$GHOSTTY_COMMIT" ]]; then
        fail "framework was built at $stamped but the source pins $GHOSTTY_COMMIT; $recovery"
    fi
    echo "Verified GhosttyKit.xcframework at pinned commit $GHOSTTY_COMMIT"
    exit 0
fi

# No stamp. The archive name still settles the one case it can: the pinned
# commit's archive is absent while an older-named one sits beside it.
found_expected=false
found_other=""
for slice in "$FRAMEWORK"/*/; do
    [[ -d "$slice" ]] || continue
    if [[ -f "$slice$GHOSTTY_ARCHIVE_NAME" ]]; then
        found_expected=true
        continue
    fi
    for archive in "$slice"libghostty*.a; do
        [[ -f "$archive" ]] || continue
        found_other="$(basename "$archive")"
    done
done

if [[ "$found_expected" == false && -n "$found_other" ]]; then
    fail "framework contains $found_other, but commit $GHOSTTY_COMMIT emits $GHOSTTY_ARCHIVE_NAME; $recovery"
fi

if [[ "$found_expected" == false ]]; then
    fail "framework contains no $GHOSTTY_ARCHIVE_NAME; $recovery"
fi

echo "WARN GhosttyKit.xcframework carries $GHOSTTY_ARCHIVE_NAME but no pin stamp; provenance is unverified"
echo "WARN rebuild or re-copy it to record the pin it was built at ($GHOSTTY_COMMIT)"
