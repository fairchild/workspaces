#!/bin/sh
set -eu

repo_root="${CI_PRIMARY_REPOSITORY_PATH:-}"
if [ -z "$repo_root" ]; then
  script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
  repo_root="$(CDPATH= cd -- "$script_dir/.." && pwd)"
fi

cd "$repo_root"

echo "Xcode Cloud post-clone setup for WorkSpaces"
echo "repo_root=$repo_root"
xcodebuild -version
swift --version

if ! command -v brew >/dev/null 2>&1; then
  echo "error: Homebrew is required in the Xcode Cloud image for WorkSpaces CI setup" >&2
  exit 1
fi

if ! command -v mise >/dev/null 2>&1; then
  brew install mise
fi

if ! command -v swift-format >/dev/null 2>&1; then
  brew install swift-format
fi

./scripts/build-ghosttykit.sh
