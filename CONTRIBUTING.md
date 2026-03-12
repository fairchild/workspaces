# Contributing

Thanks for contributing to Workspaces.

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

Install git hooks so commits run lint automatically:

```bash
mask hooks-install
```

`mask setup` now installs hooks for you as part of first-time setup.

To run the app in dev mode (isolated data directory):

```bash
./scripts/launch-dev.sh
```

Or with mask: `mask dev`

`launch-dev.sh` runs the debug binary from `.build/` with an isolated local data root. Useful options:

```bash
./scripts/launch-dev.sh --no-build      # skip rebuild, launch existing binary
./scripts/launch-dev.sh --no-activate    # don't steal foreground focus
```

If your shell restricts writes to `~/Library/Application Support`, set a custom data dir:

```bash
WORKSPACES_DATA_DIR="$PWD/.workspacemanager-data" swift run WorkspaceManager
```

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

This also links `workspaces` into the first writable directory already on your `PATH` unless you pass `--no-cli-link`.

Useful options:

```bash
./scripts/install-local.sh --no-build --no-open
./scripts/install-local.sh --signed
./scripts/install-local.sh --dest ~/Applications/WorkspaceManager.app
./scripts/install-local.sh --cli-link ~/.local/bin/workspaces
```

## CLI Development

```bash
swift run workspaces help
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

## Self-Hosted CI Runners

CI runs on a self-hosted macOS runner. The app auto-detects CI (via the standard `CI` env var) and uses `.accessory` activation policy so it never steals focus or appears in the dock. If you write a script that launches the app headlessly, set `WORKSPACES_NO_ACTIVATE_ON_LAUNCH=1`:

```bash
WORKSPACES_NO_ACTIVATE_ON_LAUNCH=1 swift run WorkspaceManager
```

## Agent Self-Verification

A bundled [tart-gui-automation](.agents/skills/tart-gui-automation/) skill lets Claude Code (or any coding agent) build and launch the app in an ephemeral Tart macOS VM, capture screenshots, and verify UI behavior without touching the host. See the CLAUDE.md "Dev Verification Practice" section for the workflow.

Requires [Tart](https://github.com/cirruslabs/tart) and a macOS guest image (`macos-tahoe-xcode`).

## Release and Signing

- Release process: [RELEASING.md](./RELEASING.md)
- Ghostty integration details: `docs/development/libghostty-integration.md`
