#!/bin/sh
# Xcode Cloud surfaces only "exited with code 1" in notifications, so this
# script runs with xtrace and an environment survey: the failing command is
# the xtrace line just above the trap's own "status=" line in the build
# report log. (The trap disables xtrace for itself so it doesn't add more
# `+` noise after that point.)
set -eux

trap 'status=$?; { set +x; } 2>/dev/null; if [ "$status" -ne 0 ]; then echo "ci_post_clone.sh: exit $status — the failing command is the xtrace line just above the final status= line" >&2; fi' EXIT

repo_root="${CI_PRIMARY_REPOSITORY_PATH:-}"
if [ -z "$repo_root" ]; then
  script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
  repo_root="$(CDPATH= cd -- "$script_dir/.." && pwd)"
fi

cd "$repo_root"

echo "Xcode Cloud post-clone setup for WorkSpaces"
echo "repo_root=$repo_root"
sw_vers
uname -m
xcodebuild -version
swift --version
df -h / || true

if ! command -v brew >/dev/null 2>&1; then
  echo "error: Homebrew is required in the Xcode Cloud image for WorkSpaces CI setup" >&2
  exit 1
fi

brew --version
export HOMEBREW_NO_AUTO_UPDATE=1

if ! command -v mise >/dev/null 2>&1; then
  brew install mise
fi

if ! command -v swift-format >/dev/null 2>&1; then
  brew install swift-format
fi

homebrew_zig_bin="/opt/homebrew/opt/zig@0.15/bin/zig"
if [ ! -x "$homebrew_zig_bin" ]; then
  brew install zig@0.15

  # Some Xcode Cloud macOS images run Homebrew from /usr/local instead of the
  # standard Apple Silicon /opt/homebrew prefix; only resolve dynamically when
  # the standard path isn't already there.
  zig_prefix="$(brew --prefix zig@0.15 2>/dev/null || true)"
  if [ -n "$zig_prefix" ] && [ -x "$zig_prefix/bin/zig" ]; then
    homebrew_zig_bin="$zig_prefix/bin/zig"
  fi
fi

if ! command -v msgfmt >/dev/null 2>&1; then
  brew install gettext
fi

gettext_prefix="$(brew --prefix gettext 2>/dev/null || true)"
if [ -n "$gettext_prefix" ] && [ -x "$gettext_prefix/bin/msgfmt" ]; then
  export PATH="$gettext_prefix/bin:$PATH"
fi

if ! command -v msgfmt >/dev/null 2>&1; then
  echo "error: msgfmt is required to build Ghostty translations; install Homebrew gettext" >&2
  exit 1
fi

msgfmt --version | head -n 1
"$homebrew_zig_bin" version

./scripts/build-ghosttykit.sh
