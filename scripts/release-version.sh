#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
INFO_PLIST_PATH="${INFO_PLIST_PATH:-$PROJECT_DIR/Sources/WorkspaceManager/Resources/Info.plist}"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/release-version.sh print
  ./scripts/release-version.sh print-build
  ./scripts/release-version.sh print-tag
  ./scripts/release-version.sh set <version> [--build <n> | --bump-build]
  ./scripts/release-version.sh assert-tag-match <tag>

Notes:
  - <version> may be passed as 0.3.0 or v0.3.0.
  - assert-tag-match accepts v<version> and workspaces-v<version>-main.<run>.
EOF
}

fail() {
  echo "release-version.sh: $*" >&2
  exit 1
}

require_info_plist() {
  [[ -f "$INFO_PLIST_PATH" ]] || fail "Info.plist not found at $INFO_PLIST_PATH"
}

plist_print() {
  local key="$1"
  /usr/libexec/PlistBuddy -c "Print :$key" "$INFO_PLIST_PATH" 2>/dev/null \
    || fail "Could not read $key from $INFO_PLIST_PATH"
}

normalize_version() {
  local raw="$1"
  raw="${raw#v}"
  [[ "$raw" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][A-Za-z0-9.]+)?$ ]] \
    || fail "Version must look like 0.3.0 or 1.0.0-beta.1 (got: $1)"
  echo "$raw"
}

normalize_tag_version() {
  local tag="$1"

  case "$tag" in
    v*)
      normalize_version "${tag#v}"
      ;;
    workspaces-v*-main.*)
      local trimmed="${tag#workspaces-v}"
      trimmed="${trimmed%-main.*}"
      normalize_version "$trimmed"
      ;;
    *)
      fail "Unsupported tag format: $tag"
      ;;
  esac
}

current_version() {
  require_info_plist
  normalize_version "$(plist_print CFBundleShortVersionString)"
}

current_build() {
  require_info_plist
  plist_print CFBundleVersion
}

set_version() {
  local version="$1"
  shift

  version="$(normalize_version "$version")"

  local build_mode="keep"
  local build_value=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --build)
        shift
        [[ $# -gt 0 ]] || fail "--build requires a value"
        build_mode="explicit"
        build_value="$1"
        ;;
      --bump-build)
        build_mode="bump"
        ;;
      *)
        fail "Unknown option: $1"
        ;;
    esac
    shift
  done

  require_info_plist
  plutil -replace CFBundleShortVersionString -string "$version" "$INFO_PLIST_PATH"

  case "$build_mode" in
    explicit)
      [[ "$build_value" =~ ^[0-9]+$ ]] || fail "Build number must be numeric (got: $build_value)"
      plutil -replace CFBundleVersion -string "$build_value" "$INFO_PLIST_PATH"
      ;;
    bump)
      local build
      build="$(current_build)"
      [[ "$build" =~ ^[0-9]+$ ]] || fail "Current build number is not numeric: $build"
      plutil -replace CFBundleVersion -string "$((build + 1))" "$INFO_PLIST_PATH"
      ;;
    keep)
      ;;
  esac

  echo "version=$(current_version)"
  echo "build=$(current_build)"
}

assert_tag_match() {
  local tag="$1"
  local expected
  local actual

  expected="$(normalize_tag_version "$tag")"
  actual="$(current_version)"

  if [[ "$expected" != "$actual" ]]; then
    fail "Tag/version mismatch: tag=$tag Info.plist=v$actual"
  fi
}

main() {
  [[ $# -gt 0 ]] || {
    usage
    exit 1
  }

  local command="$1"
  shift

  case "$command" in
    print)
      current_version
      ;;
    print-build)
      current_build
      ;;
    print-tag)
      echo "v$(current_version)"
      ;;
    set)
      [[ $# -gt 0 ]] || fail "set requires a version argument"
      set_version "$@"
      ;;
    assert-tag-match)
      [[ $# -eq 1 ]] || fail "assert-tag-match requires exactly one tag argument"
      assert_tag_match "$1"
      ;;
    --help|-h|help)
      usage
      ;;
    *)
      fail "Unknown command: $command"
      ;;
  esac
}

main "$@"
