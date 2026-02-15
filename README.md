# WorkspaceManager

A native macOS app for managing development workspaces and terminal-first AI coding sessions.

## Download

**[Download Latest Release](https://github.com/fairchild/workspaces/releases/latest)** (macOS 14.0+)

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon or Intel Mac

## Installation

### From DMG (Recommended)

1. Download the latest `.dmg` from [Releases](https://github.com/fairchild/workspaces/releases)
2. Open the DMG and drag **Workspaces** to Applications
3. Launch from Applications (first time: right-click > Open)

## Features

- Three-column layout: sidebar, terminal, and detail pane
- Host-terminal-first launch behavior with repo/workspace session switching
- Repository management and workspace creation
- Integrated GhosttyKit terminal surface
- File browser and git status view
- Lifecycle hooks (`setup.sh` / `archive.sh`)

## Usage

1. Launch app and review repositories in the sidebar
2. Add repositories manually if needed
3. Create workspaces from repo actions
4. Click repo/workspace rows to switch terminal context
5. Use the right pane for files and git changes

### CLI Usage

```bash
swift run WorkspaceManagerCLI help
```

Common workflow:

```bash
swift run WorkspaceManagerCLI repo add ~/code/my-repo
swift run WorkspaceManagerCLI ws new my-repo feature-auth
swift run WorkspaceManagerCLI open my-repo/feature-auth --cmd "claude"
```

## Configuration

Open Settings (`Cmd+,`) to configure workspace root location.

## Developer Setup and Contributing

For all development setup, local build/test workflows, contribution guidelines, and project structure, see:

- [CONTRIBUTING.md](./CONTRIBUTING.md)

For release/signing/notarization details, see:

- [RELEASING.md](./RELEASING.md)

## License

MIT
