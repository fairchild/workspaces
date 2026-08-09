# Contributing

Thanks for contributing to WorkSpaces.

## Prerequisites

- macOS 14.0+ (Sonoma or newer)
- Xcode 15.0+ or Swift 5.10+
- [mise](https://mise.jdx.dev/) (toolchain management)

## Local Setup

From repo root:

```bash
./scripts/setup  # first-run: tools, dependencies, env links, and prek hooks
```

After the first-run bootstrap, use the root `mise` tasks for normal development:

```bash
mise run build-ghosttykit  # one-time or after Ghostty pin changes
mise run build
mise run test
```

To refresh git hooks without running full setup:

```bash
mise run hooks-install
```

The underlying script path remains `./scripts/setup --hooks-only`.

To run the app in dev mode (isolated data directory):

```bash
mise run dev-launch
```

`launch-dev.sh` runs the debug binary from `.build/` with an isolated local data root. Useful options:

```bash
mise run dev-launch -- --no-build       # skip rebuild, launch existing binary
mise run dev-launch -- --no-activate    # don't steal foreground focus
```

If your shell restricts writes to `~/Library/Application Support`, set a custom data dir:

```bash
WORKSPACES_DATA_DIR="$PWD/.workspacemanager-data" swift run WorkspaceManager
```

## Daily Development Checks

Run before and after non-trivial changes:

```bash
mise run check
```

`mise run check` runs Swift format lint, `swift build`, and `swift test`.

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
./scripts/install-local.sh --dest ~/Applications/WorkSpaces.app
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
3. Run local checks (`mise run check`, or focused build/test commands when appropriate).
4. Include a concise summary of behavior changes and verification results in the PR.

## CI Runner Lanes

Generic lint/build/test CI runs on GitHub-hosted macOS (`macos-15`) and is path-scoped to product, test, build, and release inputs so docs, backlog, skill, and changelog-only pushes do not consume the hosted macOS queue. Self-hosted jobs must use explicit lanes: `[self-hosted, tart-ui]` for UI/perf automation and `[self-hosted, signing-host]` for release/signing/notarization. The `Perf Validation` workflow runs separately from the main CI workflow via `workflow_dispatch`, a nightly schedule, and scoped `codex/**` pushes so app-launching checks stay off the default path.

For this repo, the default self-hosted runner layout is:

| Runner | Labels | Location |
|--------|--------|----------|
| `blue-workspaces` | `self-hosted-macos`, optionally `signing-host` when it is serving as the release lane | `~/.local/share/actions-runner-workspaces` |
| `workspaces-tart-ui` | `tart-ui` | Tart guest `~/.local/share/actions-runner-tart-ui` |

The release workflow requires at least one online runner advertising the `signing-host` label before dispatch. That label is operational state in GitHub, not something stored in the repo. If `blue-workspaces` is not carrying the release lane, move `signing-host` to whichever signing-capable runner should own releases. See [docs/development/signing-runner-setup.md](./docs/development/signing-runner-setup.md).

### Focus stealing prevention

The app auto-detects CI (via the standard `CI` env var) and uses `.accessory` activation policy — no dock icon, no Cmd+Tab, no focus steal. Three activation modes:

| Mode | Activation Policy | Behavior |
|------|-------------------|----------|
| Normal launch | `.regular` + `activate()` | Dock + Cmd+Tab + foreground |
| `--no-activate` | `.regular`, skip `activate()` | Dock + Cmd+Tab, stays behind |
| CI (`CI=true`) | `.accessory` | Invisible |

If you write a script that launches the app headlessly, set `WORKSPACES_NO_ACTIVATE_ON_LAUNCH=1`:

```bash
WORKSPACES_NO_ACTIVATE_ON_LAUNCH=1 swift run WorkspaceManager
```

### CI visibility setup

A SwiftBar menu bar plugin shows live runner status so you know when CI is active on your machine.

**One-time setup:**

```bash
# 1. Install SwiftBar
brew install --cask swiftbar

# 2. Configure SwiftBar to use a plugin folder (e.g. ~/swiftbar)
#    Open SwiftBar preferences and set the plugin folder

# 3. Install the menu bar plugin
./scripts/install-runner-ci-menubar.sh ~/swiftbar

# 4. Install runner activity hooks (writes to all runners' .env files)
./scripts/install-runner-hooks.sh

# 5. Restart runners to pick up hooks (wait for in-flight jobs to finish)
#    The install script prints restart commands for each runner
```

**What you'll see:**

- Menu bar shows `CI` with a status icon (gray checkmark = idle, orange hammer = running)
- Click to expand: per-runner status, recent activity log
- Hooks log every job start/complete to `~/.local/share/runner-activity.log`

**CLI status check** (no SwiftBar needed):

```bash
./scripts/runner-status.sh          # snapshot
./scripts/runner-status.sh --watch  # live 5s refresh
```

### Runner scripts reference

| Script | Purpose |
|--------|---------|
| `runner-status.sh` | CLI status of all runners, WorkspaceManager processes, recent jobs |
| `runner-ci-menubar.5s.sh` | SwiftBar plugin (installed into plugin folder) |
| `install-runner-ci-menubar.sh` | Installs the SwiftBar plugin as a durable local copy |
| `runner-notify-start.sh` | Runner hook: logs job start to activity log |
| `runner-notify-complete.sh` | Runner hook: logs job completion to activity log |
| `install-runner-hooks.sh` | Installs hooks on all runners (copies scripts, updates .env) |

Parked, revival intended (owner decision 2026-08-02): kept despite low day-to-day use while the primary CI lane is GitHub-hosted/Lume-backed — do not re-flag as dead code in future cleanup passes.

The Daytona remote-workspace surface (`Sources/WorkspaceManagerCore/Services/DaytonaBackend.swift`, `scripts/daytona-sandbox-manager.py`, `web/src/lib/agent-runtime/daytona.ts` stub provider) is parked under the same 2026-08-02 owner decision — see `docs/daytona-vm.md`.

## Agent Self-Verification

A bundled [tart-gui-automation](.agents/skills/tart-gui-automation/) skill lets Claude Code (or any coding agent) build and launch the app in an ephemeral Tart macOS VM, capture screenshots, and verify UI behavior without touching the host. See `Sources/AGENTS.md` § "Dev Verification Practice" for the workflow.

Requires [Tart](https://github.com/cirruslabs/tart) and a macOS guest image (`macos-tahoe-xcode`).

## Release and Signing

- Release process: [RELEASING.md](./RELEASING.md)
- Ghostty integration details: `docs/development/libghostty-integration.md`
