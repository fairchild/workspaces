#!/usr/bin/env bash
# Prepare version metadata and changelog notes for a tester prerelease PR.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
INFO_PLIST_PATH="${INFO_PLIST_PATH:-$PROJECT_DIR/Sources/WorkspaceManager/Resources/Info.plist}"
CHANGELOG_PATH="${CHANGELOG_PATH:-$PROJECT_DIR/CHANGELOG.md}"
RELEASE_VERSION_SCRIPT="${RELEASE_VERSION_SCRIPT:-$SCRIPT_DIR/release-version.sh}"
VERSION=""
DRY_RUN=false
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/workspaces-prepare-prerelease.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage: ./scripts/prepare-prerelease.sh --version <X.Y.Z-beta.N> [--dry-run]

Options:
  --version X.Y.Z-label.N  Target semantic prerelease version
  --dry-run                Print the computed plan without mutating files
  --help, -h               Show this help

This prepares a PR. It updates Info.plist and CHANGELOG.md only; it does not
commit, tag, push, or publish a GitHub Release.
EOF
}

fail() {
  echo "[prepare-prerelease] ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

normalize_prerelease_version() {
  local raw="$1"
  raw="${raw#v}"
  [[ "$raw" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[A-Za-z0-9][A-Za-z0-9.-]*$ ]] \
    || fail "Version must be a SemVer prerelease like 0.21.0-beta.1 or 1.0.0-rc.1 (got: $1)"
  printf '%s\n' "$raw"
}

ensure_clean_worktree() {
  local status=""
  status="$(git status --porcelain)"
  [[ -z "$status" ]] || fail "Worktree must be clean before preparing a prerelease"
}

ensure_metadata_base() {
  if ! git config --get remote.origin.url >/dev/null 2>&1; then
    return 0
  fi

  git fetch origin main --tags

  local head_sha=""
  local origin_main_sha=""
  head_sha="$(git rev-parse HEAD)"
  origin_main_sha="$(git rev-parse origin/main)"

  [[ "$head_sha" == "$origin_main_sha" ]] \
    || fail "Prerelease metadata prep must run from a branch whose HEAD is current origin/main"
}

strip_prefix() {
  local subject="$1"
  printf '%s\n' "$subject" | sed -E 's/^(feat|fix|docs|chore|ci|build|refactor|style|test|perf)(\([^)]+\))?!?:[[:space:]]*//'
}

is_added_subject() {
  local subject="$1"
  local pattern='^feat(\([^)]+\))?!?:[[:space:]]*'
  [[ "$subject" =~ $pattern ]]
}

is_fixed_subject() {
  local subject="$1"
  local pattern='^fix(\([^)]+\))?!?:[[:space:]]*'
  [[ "$subject" =~ $pattern ]]
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

    if is_added_subject "$subject"; then
      printf '%s\n' "$cleaned" >>"$added_file"
      added_count=$((added_count + 1))
    elif is_fixed_subject "$subject"; then
      printf '%s\n' "$cleaned" >>"$fixed_file"
      fixed_count=$((fixed_count + 1))
    else
      printf '%s\n' "$cleaned" >>"$other_file"
      other_count=$((other_count + 1))
    fi
  done < <(git log --reverse --format='%s' "$range")

  if (( added_count == 0 && fixed_count == 0 && other_count == 0 )); then
    fail "No prerelease notes could be computed from range $range"
  fi

  {
    printf '## [%s] - %s\n\n' "$VERSION" "$(date +%F)"
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
    awk '
      NR == 1 { next }
      NR == 2 && $0 == "" { next }
      { print }
    ' "$CHANGELOG_PATH"
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

VERSION="$(normalize_prerelease_version "$VERSION")"

cd "$PROJECT_DIR"
ensure_clean_worktree
ensure_metadata_base

LATEST_STABLE_TAG="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-version:refname | grep -Ev -- '-[A-Za-z0-9]' | head -n 1 || true)"
if [[ -n "$LATEST_STABLE_TAG" ]]; then
  COMMIT_RANGE="$LATEST_STABLE_TAG..HEAD"
else
  ROOT_COMMIT="$(git rev-list --max-parents=0 HEAD | tail -n 1)"
  [[ -n "$ROOT_COMMIT" ]] || fail "Could not determine the root commit for the initial prerelease"
  COMMIT_RANGE="$ROOT_COMMIT..HEAD"
fi

build_changelog_entry "$COMMIT_RANGE"

CURRENT_BUILD="$("$RELEASE_VERSION_SCRIPT" print-build)"
TARGET_BUILD=$((CURRENT_BUILD + 1))

echo "Prerelease PR target"
echo "  version: $VERSION"
echo "  build: $TARGET_BUILD"
echo "  last stable tag: ${LATEST_STABLE_TAG:-<none>}"
echo "  commit range: $COMMIT_RANGE"
echo "  publishes when merged: manual Release workflow dispatch from main"
echo ""
echo "Computed changelog preview"
cat "$TMP_DIR/changelog-entry.txt"

if [[ "$DRY_RUN" == true ]]; then
  exit 0
fi

INFO_PLIST_PATH="$INFO_PLIST_PATH" "$RELEASE_VERSION_SCRIPT" set "$VERSION" --bump-build >/dev/null
prepend_changelog_entry

echo ""
echo "Updated:"
echo "  $INFO_PLIST_PATH"
echo "  $CHANGELOG_PATH"
echo ""
echo "Next:"
echo "  1. Review the changelog notes."
echo "  2. Open a PR with these metadata changes."
echo "  3. After merge, run Release from main to publish the tester prerelease."
