# Workspaces

**Terminal-first workspace manager for AI coding sessions on macOS.**

Workspaces gives you a native app for organizing repositories, spinning up isolated worktrees, and dropping into embedded terminal sessions. It works with any terminal-based coding agent — Claude Code, Aider, Codex CLI, or whatever you run in a shell.

[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

<!-- TODO: Add screenshot or demo gif -->

## Philosophy

Workspaces is an **agent-first codebase** — a modern baseline for building macOS developer tools with AI in the loop.

- **Any terminal agent**: The core design is an embedded terminal with workspace management chrome around it. Anything that runs in a shell works — Claude Code, Aider, Codex CLI, Copilot CLI, or a plain `bash` session.
- **Fork-friendly**: No backwards-compatibility baggage. Take what works, change what doesn't.
- **Opinionated defaults**: Three-column layout, terminal-first launch, lifecycle hooks. Sensible out of the box, fully customizable.
- **Pairs with [dotclaude](https://github.com/fairchild/dotclaude)**: The author uses Claude Code as a daily driver. Together, the two repos demonstrate a complete AI-augmented development setup — but Workspaces itself is agent-agnostic.

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
- Opens straight to a terminal — switch repos and the session follows
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

## Fork & Customize

Workspaces is designed to be forked. There's no plugin system or extension API — instead, the codebase itself is the API. Common customizations:

- **Change the layout**: Edit `ContentView.swift` to rearrange panes
- **Add lifecycle hooks**: Drop scripts into workspace directories (`setup.sh`, `archive.sh`)
- **Swap the terminal**: The `TerminalView` wrapper abstracts the terminal backend
- **Adjust keyboard shortcuts**: See `ShortcutRoutingPolicy.swift`

If you build something interesting on top of Workspaces, open an issue — we'd love to hear about it.

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

### Sandbox-Safe Local Launch

If your shell environment restricts writes to `~/Library/Application Support`, launch with a writable local data directory:

```bash
WORKSPACES_DATA_DIR="$PWD/.workspacemanager-data" swift run WorkspaceManager
```

Preferred dev launcher (recommended):

```bash
./scripts/launch-dev.sh
```

`launch-dev.sh` always runs the latest debug binary from `.build/` and defaults to an isolated local data root, which helps us dogfood and validate isolation patterns described in `backlog/isolation-strategies.md`.

Shared-desktop safe launch (do not steal foreground focus):

```bash
./scripts/launch-dev.sh --no-activate
```

## License

[Apache-2.0](LICENSE) — Copyright 2026 Michael Fairchild
