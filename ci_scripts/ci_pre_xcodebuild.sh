#!/bin/sh
set -eu

repo_root="${CI_PRIMARY_REPOSITORY_PATH:-}"
if [ -z "$repo_root" ]; then
  script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
  repo_root="$(CDPATH= cd -- "$script_dir/.." && pwd)"
fi

cd "$repo_root"

action="${CI_XCODEBUILD_ACTION:-build}"
workflow="${CI_WORKFLOW:-unknown}"

echo "Xcode Cloud pre-xcodebuild validation for WorkSpaces"
echo "workflow=$workflow"
echo "xcodebuild_action=$action"

case "$action" in
  build|analyze|"")
    ;;
  *)
    echo "Skipping full SwiftPM validation before xcodebuild action: $action"
    exit 0
    ;;
esac

if [ ! -d Frameworks/GhosttyKit.xcframework ]; then
  echo "GhosttyKit.xcframework is missing; rebuilding before validation."
  ./scripts/build-ghosttykit.sh
fi

swift-format lint --strict --recursive Sources/ Tests/
swift build
swift build -c release
swift test
