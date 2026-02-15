# Contributing

Thanks for contributing to WorkspaceManager.

## Prerequisites

- macOS 14.0+ (Sonoma or newer)
- Xcode 15.0+ or Swift 5.10+
- [mise](https://mise.jdx.dev/) (toolchain management)

## Local Setup

From repo root:

```bash
./scripts/build-ghosttykit.sh
swift build
swift test
```

To run the app from source:

```bash
./scripts/build-release.sh --no-sign
open build/WorkspaceManager.app
```

## Daily Development Checks

Run before and after non-trivial changes:

```bash
./scripts/build-ghosttykit.sh
swift-format lint --strict --recursive Sources/ Tests/
swift test
swift build
```

## Local Install Workflow

Replace your installed app in `/Applications` with your current local build:

```bash
./scripts/install-local.sh
```

Useful options:

```bash
./scripts/install-local.sh --no-build --no-open
./scripts/install-local.sh --signed
./scripts/install-local.sh --dest ~/Applications/WorkspaceManager.app
```

## CLI Development

```bash
swift run WorkspaceManagerCLI help
```

## Project Structure

```text
workspaces/
  Package.swift
  Sources/
    WorkspaceManager/        # Main app (SwiftUI + AppKit)
    WorkspaceManagerCore/    # Core models + services
    WorkspaceManagerCLI/     # CLI entrypoint
  Tests/                     # Unit tests
  scripts/                   # Build/release tooling
```

## Pull Request Guidance

1. Keep scope focused and prefer incremental, testable changes.
2. Add or update tests when behavior changes.
3. Run local checks (`swift test`, `swift build`, lint when relevant).
4. Include a concise summary of behavior changes and verification results in the PR.

## Release and Signing

- Release process: [RELEASING.md](./RELEASING.md)
- Ghostty integration details: `docs/development/libghostty-integration.md`
