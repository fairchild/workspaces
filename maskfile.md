# WorkspaceManager

This is a [maskfile](https://github.com/jacobdeichert/mask) — a task runner
that uses markdown. Install with `brew install mask`, then run `mask <task>`.

## build

> Build the project in debug mode

```bash
swift build
```

## run

> Build and launch the app

```bash
swift run
```

## test

> Run all tests

```bash
swift test
```

## release

> Build a signed .app bundle for distribution

```bash
./scripts/build-release.sh
```

## install

> Install app to /Applications and open it
> Builds an unsigned app first if `build/WorkspaceManager.app` is missing.

```bash
set -euo pipefail

APP_SRC="build/WorkspaceManager.app"
APP_DST="/Applications/WorkspaceManager.app"

if [[ ! -d "$APP_SRC" ]]; then
  echo "==> App bundle not found at $APP_SRC; building unsigned bundle first"
  ./scripts/build-release.sh --no-sign
fi

echo "==> Installing to $APP_DST"
if [[ -w "/Applications" ]]; then
  rm -rf "$APP_DST"
  ditto "$APP_SRC" "$APP_DST"
else
  sudo rm -rf "$APP_DST"
  sudo ditto "$APP_SRC" "$APP_DST"
fi

echo "==> Opening app"
open "$APP_DST"
```

## notarize

> Notarize and create DMG for distribution

```bash
./scripts/notarize.sh "$@"
```

## format

> Format all Swift source files with swift-format

```bash
swift-format format --in-place --recursive Sources/ Tests/
```

## lint

> Check formatting without modifying files (used in CI)

```bash
swift-format lint --strict --recursive Sources/ Tests/
```

## clean

> Remove build artifacts and derived data

```bash
rm -rf .build/ build/ DerivedData/
echo "Cleaned .build/, build/, DerivedData/"
```

## ci

> Run the full CI pipeline locally (build, test, lint)

```bash
set -e
echo "==> Lint"
swift-format lint --strict --recursive Sources/ Tests/
echo "==> Build"
swift build
echo "==> Test"
swift test
echo "==> All checks passed"
```

## release-alpha

> Build an unsigned alpha zip and publish a GitHub prerelease.
> Optional env vars:
> `VERSION` (default: `0.1.0-alpha.1`)
> `TAG` (default: `workspaces-v$VERSION`)
> `TARGET` (default: current git branch)

```bash
set -euo pipefail

VERSION="${VERSION:-0.1.0-alpha.1}"
TAG="${TAG:-workspaces-v$VERSION}"
TARGET="${TARGET:-$(git branch --show-current)}"
TITLE="Workspaces v$VERSION (alpha)"
ZIP_PATH="build/WorkspaceManager-$VERSION.zip"
NOTES_FILE="build/release-notes-$VERSION.md"

echo "==> Build unsigned app bundle"
./scripts/build-release.sh --no-sign

echo "==> Package zip artifact"
ditto -c -k --sequesterRsrc --keepParent build/WorkspaceManager.app "$ZIP_PATH"
SHA256="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"

cat > "$NOTES_FILE" <<EOF
## Workspaces $VERSION

This is an early alpha release for friend testing.

### Highlights
- Terminal backend migrated to GhosttyKit (libghostty)
- New runtime/input/focus terminal integration layer
- CI updated to build GhosttyKit before checks
- Docs updated with integration runbook

### Artifact
- \`$(basename "$ZIP_PATH")\`
- SHA-256: \`$SHA256\`

### Changelog
See \`CHANGELOG.md\` for details.
EOF

echo "==> Publish GitHub prerelease: $TAG"
if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "$ZIP_PATH" --clobber
  gh release edit "$TAG" --title "$TITLE" --notes-file "$NOTES_FILE" --prerelease
else
  gh release create "$TAG" "$ZIP_PATH" --title "$TITLE" --notes-file "$NOTES_FILE" --prerelease --target "$TARGET"
fi

echo "==> Published $TAG"
echo "Artifact: $ZIP_PATH"
echo "SHA-256: $SHA256"
echo "Target: $TARGET"
```
