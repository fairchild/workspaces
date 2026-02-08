# WorkspaceManager

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

## release

> Build a signed .app bundle for distribution

```bash
./scripts/build-release.sh "$@"
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
