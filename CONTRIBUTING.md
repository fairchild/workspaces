# Contributing

Thanks for contributing to WorkspaceManager.

## Prerequisites

- macOS 14.0+ (Sonoma or newer)
- Xcode 15.0+ or Swift 5.10+
- [mise](https://mise.jdx.dev/) (toolchain management)
- Optional: [mask](https://github.com/jacobdeichert/mask) (`brew install mask`) — a markdown-based task runner. If installed, you can use `mask <task>` as a shorthand for the commands below. See [maskfile.md](./maskfile.md) for all available tasks.

## Local Setup

From repo root:

```bash
./scripts/build-ghosttykit.sh  # one-time: build terminal framework
swift build
swift test
```

Or with mask: `mask setup && mask build && mask test`

Install git hooks (recommended) so commits run lint automatically:

```bash
mask hooks-install
```

To run the app in dev mode (isolated data directory):

```bash
./scripts/launch-dev.sh
```

Or with mask: `mask dev`

## Daily Development Checks

Run before and after non-trivial changes:

```bash
swift-format lint --strict --recursive Sources/ Tests/
swift build
swift test
```

Or with mask: `mask ci`

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
