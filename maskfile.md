# WorkspaceManager

This is a [maskfile](https://github.com/jacobdeichert/mask) — a task runner
that uses markdown. Install with `brew install mask`, then run `mask <task>`.

## setup

> One-time setup: build GhosttyKit framework (required before build/test)

```bash
./scripts/build-ghosttykit.sh
```

## hooks-install

> Install repo-managed git hooks (enables pre-commit lint check)

```bash
./scripts/install-git-hooks.sh
```

## build

> Build the project in debug mode

```bash
swift build
```

## test

> Run all tests

```bash
swift test
```

## dev

> Launch the app in dev mode with isolated data directory

```bash
./scripts/launch-dev.sh
```

## dev-shared

> Launch debug app without stealing focus (shared-desktop safe)

```bash
./scripts/launch-dev.sh --no-build --no-activate
```

## verify-dev

> Run the debug verification loop (build, pinned launch, process-path check, capture)

```bash
set -euo pipefail
./scripts/build-ghosttykit.sh
swift build
./scripts/launch-dev.sh --no-build --no-activate
ps aux | rg '.build/arm64-apple-macosx/debug/WorkspaceManager'
./scripts/capture-window.sh
echo "Manual checks:"
echo "  Cmd+B toggles left sidebar"
echo "  Cmd+D creates a visible right split"
```

## run

> Build and launch the app (quick, no isolation)

```bash
swift run WorkspaceManager
```

## install

> Install app to /Applications using the install script

```bash
./scripts/install-local.sh "$@"
```

## release

> Release workflows (default: build a signed .app bundle)

```bash
./scripts/build-release.sh "$@"
```

### unsigned

> Build an unsigned .app release bundle (fast local production-like check)

```bash
./scripts/build-release.sh --no-sign "$@"
```

### near-prod

> Build/sign DMG, notarize it, but skip stapling (local production-equivalent testing)

```bash
./scripts/notarize.sh --no-staple "$@"
```

### prod

> Full production package: build/sign, notarize, and staple DMG

```bash
./scripts/notarize.sh "$@"
```

### dmg-only

> Build/sign app and DMG, but skip notarization (packaging smoke test)

```bash
./scripts/notarize.sh --dmg-only "$@"
```

## notarize

> Advanced passthrough to notarize script

```bash
./scripts/notarize.sh "$@"
```

## format

> Format all Swift source files with swift-format

```bash
swift-format format --in-place --recursive Sources/ Tests/
```

## lint

> Check formatting without modifying files

```bash
swift-format lint --strict --recursive Sources/ Tests/
```

## ci

> Run the full CI pipeline locally (lint, build, test)

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

## clean

> Remove build artifacts and derived data

```bash
rm -rf .build/ build/ DerivedData/
echo "Cleaned .build/, build/, DerivedData/"
```
