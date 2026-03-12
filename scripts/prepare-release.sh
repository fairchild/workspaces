#!/bin/bash
# ============================================================================
# prepare-release.sh - Prepare and tag a versioned release from main
# ============================================================================
#
# Usage:
#   ./scripts/prepare-release.sh --version 0.4.1
#   ./scripts/prepare-release.sh --version 0.4.1 --dry-run
#   ./scripts/prepare-release.sh --version 0.4.1 --no-push
#
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
INFO_PLIST_PATH="$PROJECT_DIR/Sources/WorkspaceManager/Resources/Info.plist"
CHANGELOG_PATH="$PROJECT_DIR/CHANGELOG.md"
RELEASE_VERSION_SCRIPT="$SCRIPT_DIR/release-version.sh"
VERSION=""
DRY_RUN=false
NO_PUSH=false
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/workspaces-prepare-release.XXXXXX")"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

usage() {
    cat <<'EOF'
Usage: ./scripts/prepare-release.sh --version <X.Y.Z> [--dry-run] [--no-push]

Options:
  --version X.Y.Z   Target semantic version to release
  --dry-run         Print the computed release plan without mutating files or git
  --no-push         Create the release commit and tag locally but do not push
  --help, -h        Show this help
EOF
}

fail() {
    echo "[prepare-release] ERROR: $*" >&2
    exit 1
}

log() {
    echo "[prepare-release] $*"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

normalize_version() {
    local raw="$1"
    raw="${raw#v}"
    [[ "$raw" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][A-Za-z0-9.]+)?$ ]] \
        || fail "Version must look like 0.4.1 or 1.0.0-beta.1 (got: $1)"
    printf '%s\n' "$raw"
}

ensure_clean_worktree() {
    local status=""
    status="$(git status --porcelain)"
    [[ -z "$status" ]] || fail "Worktree must be clean before preparing a release"
}

ensure_main_branch() {
    local branch=""
    branch="$(git branch --show-current)"
    [[ "$branch" == "main" ]] || fail "prepare-release.sh must run from main (current: ${branch:-<detached>})"
}

sync_local_main() {
    git fetch origin main --tags

    local head_sha=""
    local origin_main_sha=""
    head_sha="$(git rev-parse HEAD)"
    origin_main_sha="$(git rev-parse origin/main)"

    if [[ "$head_sha" == "$origin_main_sha" ]]; then
        return 0
    fi

    if git merge-base --is-ancestor "$head_sha" "$origin_main_sha"; then
        if [[ "$DRY_RUN" == true ]]; then
            log "Dry run: local main would fast-forward from $head_sha to $origin_main_sha"
        else
            log "Fast-forwarding local main to origin/main"
            git merge --ff-only origin/main
        fi
        return 0
    fi

    fail "Local main is not a fast-forward ancestor of origin/main; reconcile main first"
}

ensure_tag_absent() {
    local tag_name="$1"

    if git rev-parse -q --verify "refs/tags/$tag_name" >/dev/null 2>&1; then
        fail "Tag already exists locally: $tag_name"
    fi

    if git ls-remote --exit-code --tags origin "refs/tags/$tag_name" >/dev/null 2>&1; then
        fail "Tag already exists on origin: $tag_name"
    fi
}

strip_prefix() {
    local subject="$1"
    printf '%s\n' "$subject" | sed -E 's/^(feat|fix|docs|chore|ci|build|refactor|style|test|perf)(\([^)]+\))?!?:[[:space:]]*//'
}

render_section_file() {
    local title="$1"
    local entries_file="$2"
    local entry=""

    [[ -s "$entries_file" ]] || return 0

    printf '### %s\n' "$title"
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        printf -- '- %s\n' "$entry"
    done <"$entries_file"
    printf '\n'
}

build_changelog_entry() {
    local range="$1"
    local added_file="$TMP_DIR/changelog-added.txt"
    local fixed_file="$TMP_DIR/changelog-fixed.txt"
    local other_file="$TMP_DIR/changelog-other.txt"
    local added_count=0
    local fixed_count=0
    local other_count=0

    local subject=""
    local cleaned=""
    : >"$added_file"
    : >"$fixed_file"
    : >"$other_file"

    while IFS= read -r subject; do
        [[ -n "$subject" ]] || continue
        [[ "$subject" == Merge\ * ]] && continue
        [[ "$subject" == release:\ * ]] && continue

        cleaned="$(strip_prefix "$subject")"
        [[ -n "$cleaned" ]] || continue

        case "$subject" in
            feat:*|feat\(*)
                printf '%s\n' "$cleaned" >>"$added_file"
                added_count=$((added_count + 1))
                ;;
            fix:*|fix\(*)
                printf '%s\n' "$cleaned" >>"$fixed_file"
                fixed_count=$((fixed_count + 1))
                ;;
            *)
                printf '%s\n' "$cleaned" >>"$other_file"
                other_count=$((other_count + 1))
                ;;
        esac
    done < <(git log --reverse --format='%s' "$range")

    if (( added_count == 0 && fixed_count == 0 && other_count == 0 )); then
        fail "No releasable commits found in range $range"
    fi

    local today=""
    today="$(date +%F)"

    {
        printf '## [%s] - %s\n\n' "$VERSION" "$today"
        render_section_file "Added" "$added_file"
        render_section_file "Fixed" "$fixed_file"
        render_section_file "Other" "$other_file"
    } >"$TMP_DIR/changelog-entry.txt"
}

prepend_changelog_entry() {
    [[ -f "$CHANGELOG_PATH" ]] || fail "CHANGELOG.md not found at $CHANGELOG_PATH"
    grep -q '^# Changelog$' "$CHANGELOG_PATH" || fail "CHANGELOG.md must start with '# Changelog'"

    {
        printf '# Changelog\n\n'
        cat "$TMP_DIR/changelog-entry.txt"
        tail -n +3 "$CHANGELOG_PATH"
    } >"$TMP_DIR/CHANGELOG.md"

    mv "$TMP_DIR/CHANGELOG.md" "$CHANGELOG_PATH"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            [[ $# -ge 2 ]] || fail "--version requires a value"
            VERSION="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --no-push)
            NO_PUSH=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            fail "Unknown argument: $1"
            ;;
    esac
done

[[ -n "$VERSION" ]] || {
    usage
    fail "--version is required"
}

require_cmd git
require_cmd date
[[ -x "$RELEASE_VERSION_SCRIPT" ]] || fail "Missing release-version helper at $RELEASE_VERSION_SCRIPT"
[[ -f "$INFO_PLIST_PATH" ]] || fail "Info.plist not found at $INFO_PLIST_PATH"

VERSION="$(normalize_version "$VERSION")"
TAG_NAME="v$VERSION"

cd "$PROJECT_DIR"

ensure_clean_worktree
ensure_main_branch
sync_local_main
ensure_tag_absent "$TAG_NAME"

LATEST_TAG="$(git tag --list 'v*' --sort=-version:refname | head -n 1)"
if [[ -n "$LATEST_TAG" ]]; then
    COMMIT_RANGE="$LATEST_TAG..HEAD"
else
    COMMIT_RANGE="HEAD"
fi

build_changelog_entry "$COMMIT_RANGE"

CURRENT_BUILD="$("$RELEASE_VERSION_SCRIPT" print-build)"
TARGET_BUILD=$((CURRENT_BUILD + 1))

echo "Release target"
echo "  version: $VERSION"
echo "  build: $TARGET_BUILD"
echo "  tag: $TAG_NAME"
echo "  last tag: ${LATEST_TAG:-<none>}"
echo "  commit range: $COMMIT_RANGE"
echo "  push main: $([[ "$NO_PUSH" == true ]] && printf 'no' || printf 'yes')"
echo "  push tag: $([[ "$NO_PUSH" == true ]] && printf 'no' || printf 'yes')"
echo ""
echo "Computed changelog preview"
cat "$TMP_DIR/changelog-entry.txt"

if [[ "$DRY_RUN" == true ]]; then
    exit 0
fi

"$RELEASE_VERSION_SCRIPT" set "$VERSION" --bump-build >/dev/null
prepend_changelog_entry

git add "$CHANGELOG_PATH" "$INFO_PLIST_PATH"
git commit -m "release: $TAG_NAME"
git tag "$TAG_NAME"

if [[ "$NO_PUSH" == true ]]; then
    log "Created release commit and local tag $TAG_NAME without pushing"
    exit 0
fi

git push origin main
git push origin "$TAG_NAME"
log "Pushed main and tag $TAG_NAME"
