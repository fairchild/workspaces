# Workspaces

**Terminal-first workspace manager for AI coding sessions on macOS.**

 Workspaces gives you a native app that wraps a terminal with some niceties for spinning up isolated workspaces. Designed to optimize terminal-based coding agent workflows.

![Workspaces main window][screenshot-main]

[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

## Philosophy

- **Any terminal agent**: Embedded terminal with workspace management around it. Anything that runs in a shell works — Claude Code, Aider, Codex CLI, or a plain `bash` session.
- **Fork-friendly**: No backwards-compatibility baggage. Take what works, change what doesn't.
- **Opinionated defaults**: Three-column layout, terminal-first launch, lifecycle hooks. Customizable by editing the source directly.

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
- Opens straight to a terminal with persistent host sessions for repo and workspace rows
- Repository management and workspace creation
- Nested workspace rows under each repo, with inline creation progress
- Integrated GhosttyKit terminal surface
- Two-pane split controls driven by Ghostty actions (`Cmd+D`, focus, resize, equalize)
- File browser and git status view
- `cmd+o` to open repo in editor, defaulting to zed
- Lifecycle hooks (`setup.sh` / `archive.sh`)

## Usage

1. Launch app and review repositories in the sidebar
2. Add repositories manually if needed
3. Create workspaces from repo actions
4. Click repo/workspace rows to switch terminal context
5. Use the right pane for files and git changes

### CLI (source builds)

```bash
swift run WorkspaceManagerCLI help
swift run WorkspaceManagerCLI repo add ~/code/my-repo
swift run WorkspaceManagerCLI ws new my-repo feature-auth
swift run WorkspaceManagerCLI open my-repo/feature-auth --cmd "claude"
```

## Configuration

Open Settings (`Cmd+,`) to configure workspace root location.

## Fork & Customize

Workspaces is designed to be forked. There's no plugin system or extension API — instead, the codebase itself is the API. Common customizations:

- **Change the layout**: Edit `ContentView.swift` to rearrange panes
- **Add lifecycle hooks**: Drop scripts into workspace directories (`setup.sh`, `archive.sh`)
- **Swap the terminal**: The `TerminalView` wrapper abstracts the terminal backend
- **Adjust keyboard shortcuts**: See `ShortcutRoutingPolicy.swift`

If you build something interesting on top of this, open an issue.

## Roadmap

[backlog/ROADMAP.md](./backlog/ROADMAP.md) and the other files in [backlog/](./backlog/) sketch a loose direction. It evolves as the project gets used and developed — nothing there is a promise.

## Developer Setup and Contributing

For all development setup, local build/test workflows, contribution guidelines, and project structure, see:

- [CONTRIBUTING.md](./CONTRIBUTING.md)

For release/signing/notarization details, see:

- [RELEASING.md](./RELEASING.md)

For performance testing and benchmarking workflows, see:

- [docs/performance-testing.md](./docs/performance-testing.md)
- [docs/performance/dashboard.md](./docs/performance/dashboard.md)

For UI smoke/capture script entry points, see:

- [scripts/README.md](./scripts/README.md)

## License

[Apache-2.0](LICENSE) — Copyright 2026 Michael Fairchild

[screenshot-main]: docs/assets/screenshot-main.jpg
