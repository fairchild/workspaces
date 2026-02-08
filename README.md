# WorkspaceManager

A native macOS app for managing development workspaces. Create isolated copies of git repositories for parallel feature work with AI coding assistants.

## Download

**[Download Latest Release](https://github.com/fairchild/workspaces/releases/latest)** (macOS 14.0+)

Or build from source (see below).

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon or Intel Mac

For development:
- Xcode 15.0+ or Swift 5.10+

## Installation

### From DMG (Recommended)

1. Download the latest `.dmg` from [Releases](https://github.com/fairchild/workspaces/releases)
2. Open the DMG and drag **Workspaces** to Applications
3. Launch from Applications (first time: right-click > Open)

### From Source

```bash
# From the repo root
swift build -c release
./scripts/build-release.sh --no-sign
open build/WorkspaceManager.app
```

## Features

- **Three-column layout**: Sidebar, terminal, and detail pane
- **Repository management**: Add existing git repositories
- **Workspace creation**: Create isolated copies with separate branches
- **Integrated terminal**: SwiftTerm-based terminal emulator
- **File browser**: View files and git changes
- **Lifecycle hooks**: Runs `setup.sh` on creation, `archive.sh` on deletion

## Usage

1. Click "Add Repository" to add a git repository
2. Right-click a repo and select "New Workspace..."
3. Enter a name - a copy is created in `~/workspaces/{repo}/{name}`
4. Select the workspace to open a terminal in that directory
5. Use the right pane to browse files and view git status

## Configuration

Open Settings (`Cmd+,`) to configure:

- **Workspaces Root**: Where workspace copies are created (default: `~/workspaces`)

## Architecture

- **WorkspaceManagerCore**: SwiftData models and services (Repo, Workspace, GitService, WorkspaceService)
- **WorkspaceManager**: SwiftUI views and terminal integration

## Tests

```bash
swift test
```

## Development

### Project Structure

```
workspaces/
  Package.swift              # SPM manifest
  Sources/
    WorkspaceManager/        # Main app (SwiftUI + AppKit)
      App/                   # App entry point
      Views/                 # SwiftUI views
      Controllers/           # AppKit controllers
      Resources/             # Info.plist, assets, privacy manifest
    WorkspaceManagerCore/    # Core library (models + services)
      Models/                # SwiftData models
      Services/              # Business logic
  Tests/                     # Unit tests
  scripts/                   # Build and release scripts
```

### Building for Release

See [RELEASING.md](./RELEASING.md) for the complete release process.

Quick local build:
```bash
./scripts/build-release.sh --no-sign  # Build without signing
./scripts/build-release.sh            # Build with signing (requires setup)
```

### Code Signing Setup

1. Copy `scripts/signing-config.sh.template` to `scripts/signing-config.sh`
2. Fill in your Apple Developer credentials
3. Run `./scripts/build-release.sh` to build and sign

## License

MIT
